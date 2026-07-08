public import Foundation

/// The embeddable OWL Chromium runtime.
///
/// Loads `libowl_fresh_mojo_runtime.dylib` from a ``ChromiumRuntimeBundle``
/// and opens ``ChromiumSession``s, each backed by its own Content Shell
/// browser process. Once started, the runtime lives for the rest of the
/// process — Chromium cannot be unloaded — so hold one instance and reuse it.
///
/// ```swift
/// let runtime = ChromiumRuntime(bundle: try ChromiumRuntimeLocator().locate())
/// try await runtime.start()
/// let session = try await runtime.openSession(initialURL: "https://example.com")
/// ```
public final class ChromiumRuntime: Sendable {
    /// The validated runtime installation this instance loads.
    public let bundle: ChromiumRuntimeBundle

    private let executor = ChromiumRuntimeExecutor()

    /// Creates a runtime for one installed bundle. Nothing loads until ``start()``.
    public init(bundle: ChromiumRuntimeBundle) {
        self.bundle = bundle
    }

    /// Loads the runtime dylib and initializes Chromium on the pinned runtime thread.
    ///
    /// Safe to call more than once; later calls return immediately.
    /// - Throws: ``ChromiumRuntimeError`` when the dylib cannot be loaded,
    ///   a symbol is missing, or global initialization fails.
    public func start() async throws {
        let libraryURL = bundle.libraryURL
        try await executor.start {
            let library = try OwlRuntimeLibrary(url: libraryURL)
            let status = library.globalInit()
            guard status == 0 else {
                throw ChromiumRuntimeError.initializationFailed(code: status)
            }
            return library
        }
    }

    /// Launches a Content Shell browser process and opens a session on it.
    ///
    /// - Parameters:
    ///   - initialURL: Page the new browser loads first.
    ///   - userDataDirectory: Profile directory for cookies/cache; `nil` uses
    ///     the shell's default. Two live sessions must not share one directory.
    ///   - proxyServer: Optional `host:port` proxy for all session traffic.
    ///   - enableDevTools: Allows ``ChromiumSession/openDevTools(mode:)``; the
    ///     shell decides at launch, so this cannot change later.
    /// - Returns: A connected session; subscribe to ``ChromiumSession/events``
    ///   before presenting it to observe the initial compositor handoff.
    public func openSession(
        initialURL: String,
        userDataDirectory: URL? = nil,
        proxyServer: String? = nil,
        enableDevTools: Bool = false
    ) async throws -> ChromiumSession {
        let shellPath = bundle.contentShellExecutableURL.path
        let userDataPath = userDataDirectory?.path
        let (events, continuation) = AsyncStream<ChromiumSessionEvent>.makeStream()
        let sink = OwlEventSink(continuation: continuation)
        let handle = try await executor.run { library -> OwlSessionHandle in
            // The runtime reads this env var during session_create to decide
            // whether the shell launches with DevTools support.
            if enableDevTools {
                setenv("OWL_FRESH_ENABLE_DEVTOOLS", "1", 1)
            } else {
                unsetenv("OWL_FRESH_ENABLE_DEVTOOLS")
            }
            let userData = Unmanaged.passRetained(sink).toOpaque()
            let raw: OpaquePointer? = shellPath.withCString { shell in
                initialURL.withCString { url in
                    userDataPath.withCStringOrNil { userDataDir in
                        if let proxyServer {
                            return proxyServer.withCString { proxy in
                                library.sessionCreateWithProxy(shell, url, userDataDir, proxy, OwlEventSink.trampoline, userData)
                            }
                        }
                        return library.sessionCreate(shell, url, userDataDir, OwlEventSink.trampoline, userData)
                    }
                }
            }
            guard let raw else {
                Unmanaged<OwlEventSink>.fromOpaque(userData).release()
                throw ChromiumRuntimeError.sessionCreateFailed
            }
            do {
                // The session only reports events and accepts commands after the
                // host binds each interface; handles are one-time nonzero tokens.
                let binds: [OwlRuntimeLibrary.SessionBindFn] = [
                    library.sessionSetClient,
                    library.sessionBindWebView,
                    library.sessionBindInput,
                    library.sessionBindSurfaceTree,
                    library.sessionBindNativeSurfaceHost,
                    library.sessionBindDevToolsHost,
                    library.sessionBindProfile,
                ]
                for bind in binds {
                    var error: UnsafeMutablePointer<CChar>?
                    let status = bind(raw, 1, &error)
                    try library.throwIfFailed(status, error)
                }
                var ok = false
                var error: UnsafeMutablePointer<CChar>?
                let status = library.sessionFlush(raw, &ok, &error)
                try library.throwIfFailed(status, error)
            } catch {
                library.sessionDestroy(raw)
                Unmanaged<OwlEventSink>.fromOpaque(userData).release()
                throw error
            }
            return OwlSessionHandle(raw: raw)
        }
        return ChromiumSession(executor: executor, handle: handle, sink: sink, events: events)
    }
}
