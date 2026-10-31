public import CmuxNextSettings
public import Foundation

/// One page operation on a browser tab the app hosts (WebKit or Chromium).
/// The daemon owns the tab's placement; the app owns its page, so page
/// commands for app browser tabs come here (plans/cmux-next/cli.md, C9).
public enum BrowserPageOperation: Sendable, Hashable {
    case navigate(String)
    case back, forward, reload
    /// Result: `{"url": …, "title": …}`.
    case state
    /// Result: `{"value": <JSON>}`.
    case evaluate(String)
    /// Runs the body of an async function and awaits what it returns.
    /// Result: `{"value": <JSON>}`.
    case evaluateAsync(String)
    /// Runs `script` as an expression in cmux's isolated script world, which page scripts and
    /// agent scripts (`evaluate`, `evaluateAsync`, both the page's world) never reach: its globals
    /// and prototypes are its own, while the DOM is shared. Result: `{"value": <JSON>}`.
    case evaluateIsolated(String)
    /// Result: `{"png_base64": …, "width": …, "height": …}` (image pixels).
    case screenshot(BrowserPageCapture)
    /// The cookies of the tab's profile. Result: `{"cookies": [cookie JSON]}`
    /// for `.list`, `{}` otherwise.
    case cookies(BrowserPageCookieRequest)
    /// Native input to the page (trusted events with the browser's default actions). Result:
    /// `{"native": true}` when the engine delivered it; any other result (`{"native": false,
    /// "reason": …}`, an engine without native input) makes the caller fall back to page events.
    case input(BrowserPageInput)
    /// Offers files to the next file chooser the page opens, runs `script` (it clicks the element that opens
    /// one) and waits for the chooser (``BrowserPageUpload``). Result: `{"value": <the script's answer>,
    /// "chooser": "chosen" | "withdrawn" | "unsupported" | <refusal code>}`.
    case upload(BrowserPageUpload)
}

/// `browser.page.upload` through the page's own file chooser, as a person's click does: real files, any
/// size, from any element that opens a chooser (a hidden input, a button, a label).
public struct BrowserPageUpload: Sendable, Hashable {
    /// A page script that clicks the element; answers `{value, at}` or `{error, code}`.
    public var script: String
    /// Absolute file URLs; a folder's has `hasDirectoryPath`.
    public var files: [URL]
    /// How long after the click a chooser may open.
    public var within: Duration

    public init(script: String, files: [URL], within: Duration) {
        self.script = script
        self.files = files
        self.within = within
    }
}

/// One row of the app's downloads list, as `browser.page.downloads` reports it.
public struct BrowserPageDownload: Sendable, Hashable {
    public var id: String
    public var filename: String
    /// `in_progress`, `finished`, `failed`, `cancelled` or `blocked`.
    public var status: String
    /// Why it failed or was blocked.
    public var reason: String?
    public var paused: Bool
    public var received: Int64
    public var total: Int64?
    public var url: String?
    /// Where the file is, once it landed.
    public var path: String?
    /// The tab it came from, when it started in this run.
    public var tab: String?

    public init(id: String, filename: String, status: String, reason: String? = nil, paused: Bool = false,
                received: Int64 = 0, total: Int64? = nil, url: String? = nil, path: String? = nil, tab: String? = nil) {
        self.id = id
        self.filename = filename
        self.status = status
        self.reason = reason
        self.paused = paused
        self.received = received
        self.total = total
        self.url = url
        self.path = path
        self.tab = tab
    }

    var json: JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(id), "filename": .string(filename), "status": .string(status), "paused": .bool(paused),
            "received": .number(Double(received)), "total": total.map { .number(Double($0)) } ?? .null,
            "url": url.map(JSONValue.string) ?? .null, "path": path.map(JSONValue.string) ?? .null,
            "tab": tab.map(JSONValue.string) ?? .null,
        ]
        if let reason { row["reason"] = .string(reason) }
        return .object(row)
    }
}

/// What the engine answers a ``BrowserPageDownloadQuery`` with.
public enum BrowserPageDownloads: Sendable, Hashable {
    case list([BrowserPageDownload])
    /// A wait's download ended (in any status).
    case ended(BrowserPageDownload)
    /// No listed download has the asked id.
    case unknownID
    /// Nothing ended in time.
    case timedOut
}

/// `browser.page.downloads` and `browser.page.download.wait`: the app's downloads list.
public struct BrowserPageDownloadQuery: Sendable, Hashable {
    /// Only downloads this tab started (public id); nil for every tab's.
    public var tabID: String?
    /// One download by id (`list` rows' `id`); for a wait.
    public var id: String?
    /// The newest rows at most, for a list.
    public var limit: Int?
    /// How long a wait lasts; nil lists without waiting.
    public var wait: Duration?

    public init(tabID: String?, id: String? = nil, limit: Int? = nil, wait: Duration? = nil) {
        self.tabID = tabID
        self.id = id
        self.limit = limit
        self.wait = wait
    }
}

/// Runs page operations for the app. The App hops to the main actor itself;
/// the request deadline bounds the call.
public protocol BrowserPageEngine: Sendable {
    /// `tabID` is the tab's public id (`tab_…`); `url` is the tab's last
    /// known URL, for an engine that must load the page first.
    func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue

    /// An agent input a `browser.page.*` command made in tab `tabID`, after
    /// it ran: the app draws its agent cursor there. The default does nothing.
    func announce(_ input: BrowserPageAgentInput, tabID: String) async

    /// The downloads `query` names: a list (oldest first), or for a wait the download that ended. The
    /// default has no downloads.
    func downloads(_ query: BrowserPageDownloadQuery) async throws -> BrowserPageDownloads
}

extension BrowserPageEngine {
    public func announce(_ input: BrowserPageAgentInput, tabID: String) async {}

    public func downloads(_ query: BrowserPageDownloadQuery) async throws -> BrowserPageDownloads {
        throw ControlError(code: "unsupported", message: ControlStrings.text("control.error.downloadsUnsupported",
                                                                              "This app keeps no browser downloads"))
    }
}
