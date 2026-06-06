import Foundation

/// Caller-supplied configuration for `CEFEngine.start`.
///
/// The configuration is immutable once `CEFEngine.start` has been called.
/// To change any of these values, cmux must restart the process.
public struct CEFEngineConfig: Sendable, Equatable {

    /// Absolute path to the root cache directory. cmux owns this directory.
    /// All per-profile cache directories live underneath it.
    ///
    /// Recommended: `~/Library/Application Support/<bundle id>/CEFRoot`.
    public let rootCachePath: URL

    /// Absolute filesystem paths to unpacked Chrome extensions to load at
    /// process startup. CEF Chrome runtime serializes these into a single
    /// `--load-extension` command-line switch passed to Chromium. All
    /// profiles share the same available extension set; per-profile state
    /// (storage, cookies, login, options-page settings) stays isolated.
    public let extensionDirectories: [URL]

    /// CEF log severity. 0 = default, 1 = verbose, 2 = info, 3 = warning,
    /// 4 = error, 5 = fatal.
    public let logSeverity: Int

    /// Whether to disable Chromium's process sandbox for this engine run.
    ///
    /// Development and ad-hoc signed helper builds need this because their
    /// helpers do not carry Chromium's sandbox signing profile. Production
    /// callers should leave the sandbox enabled unless their signing pipeline
    /// deliberately opts out.
    public let disableSandbox: Bool

    /// Whether to disable Chromium GPU acceleration for this engine run.
    ///
    /// Development and ad-hoc signed helpers can opt into CPU compositing when
    /// their bundle layout cannot satisfy the GPU helper's dylib lookup. Release
    /// callers should leave this false so Chromium can use GPU compositing.
    public let disableGPUAcceleration: Bool

    /// Optional product suffix shown in user-agent and chrome://version.
    public let userAgentProduct: String?

    /// Optional. Directory holding `Chromium Embedded Framework.framework`
    /// and the helper .app bundles. Leave nil when cmux is running inside
    /// a proper .app bundle; supply explicitly when running as a CLI
    /// (e.g. `swift run`) so CEF can locate `icudtl.dat` and helpers.
    public let frameworkDirectoryPath: URL?

    /// Optional. Path to the CEF helper executable to spawn for
    /// renderer/GPU/utility processes. Required when running outside an
    /// .app bundle.
    public let browserSubprocessPath: URL?

    /// Creates an immutable CEF engine configuration.
    ///
    /// - Parameters:
    ///   - rootCachePath: Absolute path to the engine root cache directory.
    ///   - extensionDirectories: Unpacked Chrome extensions to expose to all profiles.
    ///   - logSeverity: CEF log severity override, or `0` for CEF's default.
    ///   - disableSandbox: Whether to disable Chromium's process sandbox.
    ///   - disableGPUAcceleration: Whether to disable Chromium GPU compositing.
    ///   - userAgentProduct: Optional product suffix shown in CEF user-agent metadata.
    ///   - frameworkDirectoryPath: Optional directory containing the CEF framework.
    ///   - browserSubprocessPath: Optional helper executable for CEF subprocesses.
    public init(
        rootCachePath: URL,
        extensionDirectories: [URL] = [],
        logSeverity: Int = 0,
        disableSandbox: Bool = false,
        disableGPUAcceleration: Bool = false,
        userAgentProduct: String? = nil,
        frameworkDirectoryPath: URL? = nil,
        browserSubprocessPath: URL? = nil
    ) {
        self.rootCachePath = rootCachePath
        self.extensionDirectories = extensionDirectories
        self.logSeverity = logSeverity
        self.disableSandbox = disableSandbox
        self.disableGPUAcceleration = disableGPUAcceleration
        self.userAgentProduct = userAgentProduct
        self.frameworkDirectoryPath = frameworkDirectoryPath
        self.browserSubprocessPath = browserSubprocessPath
    }
}
