import AppKit
import Darwin

/// cmux's side of remote Cocoa pages (fork API 37; in-tree pages approach 4, prototype behind
/// `browserHost.helperPrototype`): Chromium's browser process runs in the Chromium host app, and the page's own
/// `WebContentsViewCocoa` and `RenderWidgetHostViewCocoa` are made in this process by Chromium's remote_cocoa
/// bridges, inside a cmux view, as Chrome's PWA app shims get theirs.
///
/// The bridges live in the Chromium framework this app already embeds: the framework is mapped (the same load the
/// in-process engine uses, ``CEFRuntime/preload(layout:)``, off the main thread) but `CefInitialize` never runs for
/// it. `cmux_rc_client_connect` starts only what the bridges need (mojo, an IO thread, a main-thread task runner
/// on a run loop source) and connects to the host's bootstrap name.
@MainActor
final class ChromiumRemoteCocoaClient {
    static let shared = ChromiumRemoteCocoaClient()

    private typealias Connect = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias Connected = @convention(c) (Int32) -> Int32
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Int32
    private typealias Adopt = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32

    private struct Calls {
        var connect: Connect
        var connected: Connected
        var register: Register
        var adopt: Adopt
    }

    private var calls: Calls?
    private var loading: Task<String?, Never>?
    /// The first cmux view id; hosts count their own ids from `pid << 32` (fork patch cmux_remote_cocoa_view_ids).
    private var nextViewID: UInt64 = 1 << 62
    /// Main-thread time of each connect (ms), for the startup measure.
    private(set) var connectMilliseconds: [Double] = []
    private(set) var loadMilliseconds: Double?
    /// Whose Chromium runtime serves the bridges: `own` (this process runs no `CefInitialize`; the bridges get a
    /// runtime of their own) or `shared` (the in-process engine was already up, so its loop runs them).
    private(set) var runtimeMode = ""

    /// A new id for a cmux view pages may go into.
    func makeViewID() -> UInt64 {
        nextViewID += 1
        return nextViewID
    }

    /// Maps the framework (once) and binds the fork's calls. Nil on success, else why not.
    func prepare() async -> String? {
        if calls != nil { return nil }
        if let loading { return await loading.value }
        let task = Task { @MainActor [weak self] () -> String? in
            guard let self else { return "gone" }
            let started = ContinuousClock.now
            let runtime = CEFRuntime.shared
            let binary: URL
            if runtime.state == .ready, let layout = runtime.layout {
                binary = layout.frameworkBinary
                self.runtimeMode = "shared"
            } else {
                if runtime.loadTask == nil, runtime.state == .idle { runtime.preload() }
                guard let task = runtime.loadTask else { return "the Chromium framework is not loading (\(runtime.state))" }
                switch await task.value {
                case .success(let library): binary = library.layout.frameworkBinary
                case .failure(let error): return "framework load failed: \(error)"
                }
                if runtime.state == .ready {
                    self.runtimeMode = "shared"
                } else {
                    // The bridges' own runtime (mojo, a task executor on the main thread) and CefInitialize cannot
                    // both run in one process: from here on the in-process engine does not start (a warm start
                    // still waiting checks this state before CefInitialize).
                    runtime.state = .failed("this process shows Chromium pages from the Chromium host app (remote Cocoa prototype)")
                    self.runtimeMode = "own"
                }
            }
            self.loadMilliseconds = Self.milliseconds(ContinuousClock.now - started)
            // Already mapped: RTLD_NOLOAD returns its handle without loading.
            guard let handle = dlopen(binary.path, RTLD_NOLOAD | RTLD_LAZY | RTLD_LOCAL) else {
                return "framework not mapped: \(dlerror().map { String(cString: $0) } ?? "no dlerror")"
            }
            func symbol<T>(_ name: String, _: T.Type) -> T? {
                dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
            }
            guard let connect = symbol("cmux_rc_client_connect", Connect.self),
                  let connected = symbol("cmux_rc_client_connected", Connected.self),
                  let register = symbol("cmux_rc_client_register_view", Register.self),
                  let adopt = symbol("cmux_rc_client_adopt_page", Adopt.self)
            else { return "this Chromium framework has no remote Cocoa pages (fork API 37)" }
            self.calls = Calls(connect: connect, connected: connected, register: register, adopt: adopt)
            return nil
        }
        loading = task
        let result = await task.value
        if result != nil { loading = nil }
        return result
    }

    /// Connects to a host's bootstrap name: a connection number (>= 1), or 0.
    func connect(_ name: String) -> Int32 {
        guard let calls else { return 0 }
        let started = ContinuousClock.now
        let connection = name.withCString { calls.connect($0) }
        connectMilliseconds.append(Self.milliseconds(ContinuousClock.now - started))
        return connection
    }

    func isConnected(_ connection: Int32) -> Bool {
        guard let calls, connection > 0 else { return false }
        return calls.connected(connection) == 1
    }

    /// `view` takes pages under `id` (retained by the fork while registered); nil unregisters.
    @discardableResult
    func register(_ view: NSView?, id: UInt64) -> Bool {
        guard let calls else { return false }
        let pointer = view.map { Unmanaged.passUnretained($0).toOpaque() }
        return calls.register(pointer, id) == 1
    }

    /// The page's `WebContentsViewCocoa` arrived in `container`: it fills it and carries the in-tree marks.
    @discardableResult
    func adopt(page: NSView, in container: NSView) -> Bool {
        guard let calls else { return false }
        return calls.adopt(Unmanaged.passUnretained(container).toOpaque(), Unmanaged.passUnretained(page).toOpaque()) == 1
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
