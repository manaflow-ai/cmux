import AppKit
import Foundation
import CMUXCEFBridge

/// Engine errors. Domain `CMUXCEF` codes mirror `CMUXCEFInitError` from the
/// ObjC++ bridge.
public enum CEFEngineError: Error, Sendable, Equatable {
    case alreadyInitialized
    case missingRootCachePath
    case cefInitializeFailed(message: String?)
    case unsupportedOperatingSystem(minimum: String)
    case bridge(NSError)
}

/// Process-wide CEF lifecycle. There is exactly one engine per cmux
/// process; the singleton is acquired through `CEFEngine.shared`.
///
/// Usage from cmux's app delegate:
///
/// ```swift
/// // 1. In main(), before AppKit boots, route subprocess invocations.
/// let exitCode = CEFEngine.executeSubprocessIfNeeded()
/// if exitCode >= 0 { exit(exitCode) }
///
/// // 2. In applicationDidFinishLaunching:
/// try CEFEngine.shared.start(config: .init(
///     rootCachePath: rootCacheURL,
///     extensionDirectories: cmux.curatedExtensionURLs))
///
/// // 3. In applicationWillTerminate:
/// CEFEngine.shared.shutdown()
/// ```
///
/// Threading: every public method is `MainActor`. The ObjC++ bridge dispatches
/// CEF UI thread tasks where required.
@MainActor
public final class CEFEngine {

    public static let shared = CEFEngine()

    private let cefBridge = CMUXCEFEngineBridge.shared()
    private(set) public var config: CEFEngineConfig?
    private var hasShutdown = false

    private init() {}

    /// Route the current process to a CEF helper loop when invoked as such
    /// by CEF's multi-process launcher. The cmux app's `main()` MUST call
    /// this first. The returned value is either an exit code (caller exits
    /// immediately) or `-1` (caller continues normal browser-process
    /// startup).
    ///
    /// This is `nonisolated` because main() runs before any actor is set up.
    public nonisolated static func executeSubprocessIfNeeded() -> Int32 {
        let argv = CommandLine.unsafeArgv
        let argc = Int32(CommandLine.arguments.count)
        let code = Int32(CMUXCEFEngineBridge.executeSubprocessIfNeeded(argc: argc, argv: argv))
        return code
    }

    /// Initialize CEF. Throws `.alreadyInitialized` if called twice in the
    /// same process.
    public func start(config: CEFEngineConfig) throws {
        guard #available(macOS 15.0, *) else {
            throw CEFEngineError.unsupportedOperatingSystem(minimum: "macOS 15.0")
        }
        guard !hasShutdown, self.config == nil else {
            throw CEFEngineError.alreadyInitialized
        }

        let bridgeConfig = CMUXCEFEngineConfigBridge()
        bridgeConfig.rootCachePath = config.rootCachePath.path
        bridgeConfig.loadExtensionsArg = Self.serializeLoadExtensionsArg(
            config.extensionDirectories)
        bridgeConfig.logSeverity = config.logSeverity
        bridgeConfig.userAgentProduct = config.userAgentProduct
        bridgeConfig.frameworkDirectoryPath = config.frameworkDirectoryPath?.path
        bridgeConfig.browserSubprocessPath = config.browserSubprocessPath?.path

        do {
            try cefBridge.initialize(withConfig: bridgeConfig)
        } catch {
            let nsError = error as NSError
            if nsError.domain == "CMUXCEF" {
                switch nsError.code {
                case 1: throw CEFEngineError.alreadyInitialized
                case 2: throw CEFEngineError.missingRootCachePath
                case 3: throw CEFEngineError.cefInitializeFailed(
                    message: nsError.localizedDescription)
                default: break
                }
            }
            throw CEFEngineError.bridge(nsError)
        }
        self.config = config
    }

    /// Idempotent. After shutdown, calling `start` again in the same process
    /// is undefined behaviour (CEF doesn't support `CefInitialize` twice).
    public func shutdown() {
        guard config != nil else { return }
        cefBridge.shutdown()
        config = nil
        hasShutdown = true
    }

    public var isRunning: Bool { cefBridge.isInitialized }

    /// Block on the CEF UI message loop. cmux app should NOT use this;
    /// it's intended for CLI integration tests (`swift run`) that don't
    /// otherwise run an AppKit event loop.
    public func runMessageLoop() {
        cefBridge.runMessageLoop()
    }

    /// Unblock `runMessageLoop`.
    public func quitMessageLoop() {
        cefBridge.quitMessageLoop()
    }

    private static func serializeLoadExtensionsArg(_ urls: [URL]) -> String? {
        guard !urls.isEmpty else { return nil }
        return urls.map(\.path).joined(separator: ",")
    }
}
