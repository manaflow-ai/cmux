/// The versions of the browser engine that runs the pages, for crash
/// reports: a renderer crash or a net error often depends on the Chromium
/// build.
///
/// Every field is nil when the engine did not say (stock CEF has no fork API;
/// a failed symbol lookup gives no versions).
public nonisolated struct BrowserEngineVersions: Hashable, Sendable {
    /// The CEF version, `156.0.15`.
    public var cef: String?
    /// The Chromium version CEF is built on, `156.0.8078.80`.
    public var chromium: String?
    /// The cmux CEF fork's API version (`cmux_shim_fork_api_version`); nil
    /// or 0 for stock CEF.
    public var forkAPI: Int?

    /// - Parameters:
    ///   - cef: The CEF version (major.minor.patch).
    ///   - chromium: The Chromium version (major.minor.build.patch).
    ///   - forkAPI: The cmux fork's API version, when the fork runs.
    public init(cef: String? = nil, chromium: String? = nil, forkAPI: Int? = nil) {
        self.cef = cef
        self.chromium = chromium
        self.forkAPI = forkAPI
    }

    /// The versions from CEF's `cef_version_info(entry)` (entries 0 to 2: CEF
    /// major, minor, patch; 4 to 7: Chromium major, minor, build, patch).
    /// - Parameters:
    ///   - info: `cef_version_info`, or a test's stand-in.
    ///   - forkAPI: The cmux fork's API version, when the fork runs.
    /// - Returns: The versions; a version whose major is 0 is nil.
    public static func cef(info: (Int32) -> Int32, forkAPI: Int? = nil) -> BrowserEngineVersions {
        func join(_ entries: [Int32]) -> String? {
            let parts = entries.map(info)
            guard let major = parts.first, major > 0 else { return nil }
            return parts.map(String.init).joined(separator: ".")
        }
        return BrowserEngineVersions(cef: join([0, 1, 2]), chromium: join([4, 5, 6, 7]),
                                     forkAPI: forkAPI.flatMap { $0 > 0 ? $0 : nil })
    }
}
