/// A Chromium download event from the CEF shim (`DOWNLOAD_STARTED`,
/// `DOWNLOAD_PROGRESS`, `DOWNLOAD_DONE`), decoded. `token` is the shim's
/// download token: unique across profiles in one process (Chromium's own
/// download ids are per request context).
public enum BrowserChromiumDownloadEvent: Equatable, Sendable {
    /// How a download ended.
    public enum End: Int64, Equatable, Sendable {
        case complete = 1
        case cancelled = 2
        case interrupted = 3
    }

    /// Shim event kinds (`cmux_cef_shim.h`).
    public static let startedKind: Int32 = 34
    public static let progressKind: Int32 = 35
    public static let doneKind: Int32 = 36

    /// Chromium waits for the download's path (`cmux_shim_download_continue`).
    /// `browser` is the CEF browser id of the tab that started it, or 0.
    case started(token: Int32, browser: Int32, url: String, suggestedName: String, totalBytes: Int64?)
    case progress(token: Int32, receivedBytes: Int64, totalBytes: Int64?, bytesPerSecond: Int64?, paused: Bool)
    /// `reason` is Chromium's interrupt reason (0 when none); `path` where it wrote.
    case done(token: Int32, end: End, reason: Int64, path: String)

    /// Decodes a shim event; `nil` for another kind or a malformed one.
    public init?(kind: Int32, browser: Int32, token: Int32, a: Int64, b: Int64, s1: String, s2: String) {
        switch kind {
        case Self.startedKind:
            self = .started(token: token, browser: browser, url: s1, suggestedName: s2, totalBytes: a > 0 ? a : nil)
        case Self.progressKind:
            self = .progress(token: token, receivedBytes: max(a, 0), totalBytes: b > 0 ? b : nil,
                             bytesPerSecond: Int64(s1), paused: s2 == "paused")
        case Self.doneKind:
            guard let end = End(rawValue: a) else { return nil }
            self = .done(token: token, end: end, reason: b, path: s1)
        default:
            return nil
        }
    }

    /// The shim token the event belongs to.
    public var token: Int32 {
        switch self {
        case let .started(token, _, _, _, _), let .progress(token, _, _, _, _), let .done(token, _, _, _): token
        }
    }
}
