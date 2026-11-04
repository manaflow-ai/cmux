/// Why the Chromium engine cannot open a tab, typed for diagnostics
/// (`debug.cef`) and for the WebKit fallback notice.
public nonisolated enum CEFUnavailableReason: Equatable, Sendable {
    /// The runtime was not embedded in this app bundle (fleet and CI builds
    /// have no CEF artifact) and the build has no runtime pack to download.
    case notBundled
    /// The build downloads Chromium on first use and it is not installed
    /// yet (plans/cmux-next/bundle-size-DESIGN.md section 6). `fraction` is
    /// the download progress from 0 to 1, nil before bytes flow (waiting for
    /// the network, verifying, unpacking).
    case downloading(fraction: Double?)
    /// The last download or install attempt failed; another follows. The
    /// message says why (for diagnostics; the UI shows a summary).
    case downloadFailed(String)
    /// Loading the framework or `CefInitialize` failed; the message says why.
    case startFailed(String)
    /// CEF shut down (the app is quitting); it cannot start again.
    case shutDown
    /// The app's open-file limit (the soft limit, after the app's own raise) is below what Chromium
    /// needs, so Chromium was not started: it would abort the app when it runs out
    /// (`OpenFileLimit.chromiumFloor`). A launch under a lowered hard limit (`ulimit -n`).
    case openFileLimit(UInt64)

    /// Stable code for diagnostics: `notBundled`, `downloading`,
    /// `downloadFailed`, `startFailed`, `shutDown`, `openFileLimit`.
    public var code: String {
        switch self {
        case .notBundled: "notBundled"
        case .downloading: "downloading"
        case .downloadFailed: "downloadFailed"
        case .startFailed: "startFailed"
        case .shutDown: "shutDown"
        case .openFileLimit: "openFileLimit"
        }
    }

    /// The failure message for `startFailed` and `downloadFailed`; for `openFileLimit`, the localized
    /// text that names the limit and how to start cmux with a higher one.
    public var detail: String? {
        switch self {
        case .startFailed(let message), .downloadFailed(let message): message
        case .openFileLimit(let limit): Strings.cefOpenFileLimit(limit)
        case .notBundled, .downloading, .shutDown: nil
        }
    }

    /// True when a Chromium tab must wait in place instead of loading in WebKit: Chromium failed to start in this
    /// process (`CefInitialize` runs once per process), and WebKit has none of Chromium's cookies, so a signed-in
    /// page would come back signed out (github.com/login?return_to=…, field log 2026-10-26). A build without
    /// Chromium or one still downloading it keeps the WebKit fallback.
    public var keepsChromiumTabsOutOfWebKit: Bool {
        switch self {
        case .startFailed, .openFileLimit: true
        case .notBundled, .downloading, .downloadFailed, .shutDown: false
        }
    }

    /// The notice of a Chromium tab that waits in place (``keepsChromiumTabsOutOfWebKit``) when the reason
    /// names its own way out: the open-file limit, where a reopen from the same shell would not help. Nil
    /// for the App's generic "quit and reopen" notice.
    public var waitingTabNotice: String? {
        if case .openFileLimit = self { return detail }
        return nil
    }

    /// True while the runtime is still on its way (downloading or retrying):
    /// a Chromium request should start or hurry the download.
    public var isAwaitingDownload: Bool {
        switch self {
        case .downloading, .downloadFailed: true
        case .notBundled, .startFailed, .shutDown, .openFileLimit: false
        }
    }
}
