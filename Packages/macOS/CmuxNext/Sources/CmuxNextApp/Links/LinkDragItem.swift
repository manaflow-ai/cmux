import Foundation

/// A link dragged out of a chat bubble (Home's transcript) that a pane drop zone can open: a web
/// page in a cmux browser tab, or a file in its file page. Other links (`mailto:`, a cmux app
/// link, a relative path) do not drag; their press selects text as before.
enum LinkDragItem: Equatable {
    /// An http or https page.
    case web(URL)
    /// An absolute `file://` path.
    case file(URL)

    /// The item `url` drags as, or nil when it does not drag. `browserEnabled`: the cmux browser is
    /// on (`browser.enabled`); off, a web link has nowhere in cmux to open and does not drag.
    init?(_ url: URL, browserEnabled: Bool) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            guard browserEnabled, url.host?.isEmpty == false else { return nil }
            self = .web(url)
        case "file":
            guard url.path.hasPrefix("/") else { return nil }
            self = .file(url.standardizedFileURL)
        default:
            return nil
        }
    }

    var url: URL {
        switch self {
        case .web(let url), .file(let url): url
        }
    }

    /// The ghost's text: the host and path of a page (no scheme), the name of a file.
    var title: String {
        switch self {
        case .web(let url):
            let path = url.path == "/" ? "" : url.path
            return (url.host ?? url.absoluteString) + path
        case .file(let url):
            return url.lastPathComponent
        }
    }
}
