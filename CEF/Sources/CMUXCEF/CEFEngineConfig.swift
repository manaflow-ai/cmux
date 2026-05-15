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

    public init(
        rootCachePath: URL,
        extensionDirectories: [URL] = [],
        logSeverity: Int = 0,
        userAgentProduct: String? = nil,
        frameworkDirectoryPath: URL? = nil,
        browserSubprocessPath: URL? = nil
    ) {
        self.rootCachePath = rootCachePath
        self.extensionDirectories = extensionDirectories
        self.logSeverity = logSeverity
        self.userAgentProduct = userAgentProduct
        self.frameworkDirectoryPath = frameworkDirectoryPath
        self.browserSubprocessPath = browserSubprocessPath
    }
}
