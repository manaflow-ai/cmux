public import Foundation

/// One entry of a Chromium page's session history.
public struct CEFNavigationEntry: Equatable, Sendable {
    public var url: URL?
    /// The page title, nil when the page had none.
    public var title: String?
    /// Steps from the current entry: negative is back, positive forward
    /// (what ``CEFBrowser/goToEntry(offset:)`` takes).
    public var offset: Int
}

/// A Chromium page's back/forward list (`cmux_shim_tab_navigation_entries`):
/// entries oldest first and the current index. Ported from cmux Next
/// `CEF/CEFNavigationEntries.swift` and `CEF/CEFTab+BackForwardList.swift`.
public struct CEFNavigationList: Equatable, Sendable {
    public var entries: [CEFNavigationEntry]
    public var currentIndex: Int

    public var current: CEFNavigationEntry? {
        entries.indices.contains(currentIndex) ? entries[currentIndex] : nil
    }

    /// The Back button's menu: nearest entry first.
    public var backEntries: [CEFNavigationEntry] {
        guard current != nil else { return [] }
        return entries[..<currentIndex].reversed()
    }

    /// The Forward button's menu: nearest entry first.
    public var forwardEntries: [CEFNavigationEntry] {
        guard current != nil else { return [] }
        return Array(entries[(currentIndex + 1)...])
    }

    /// Parses the shim's JSON (`{"current": i, "entries": [{"url", "title"}]}`);
    /// nil when it is malformed or lists nothing.
    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["entries"] as? [[String: Any]], !list.isEmpty else { return nil }
        let current = object["current"] as? Int ?? -1
        currentIndex = current
        entries = list.enumerated().map { index, item in
            let title = item["title"] as? String ?? ""
            return CEFNavigationEntry(
                url: (item["url"] as? String).flatMap(URL.init(string:)),
                title: title.isEmpty ? nil : title,
                offset: index - current
            )
        }
    }
}

/// Chromium's back/forward entries for Back and Forward history menus,
/// from fork API 14 (`cmux_shim_tab_navigation_entries`,
/// `cmux_shim_tab_go_to_entry`). An older fork lists nothing.
extension CEFBrowser {
    static let backForwardListForkAPI: Int32 = 14

    /// The page's back/forward list, nil before the page exists or on a
    /// fork without the API.
    public func navigationList() -> CEFNavigationList? {
        guard let id = browserID, let shim = runtime.shim, runtime.forkAPIVersion >= Self.backForwardListForkAPI,
              let json = shim.takeString(shim.tabNavigationEntries(id)) else { return nil }
        return CEFNavigationList(json: json)
    }

    /// Navigates `offset` entries from the current one (negative is back).
    /// False when the page or the fork API is missing, or Chromium refused.
    @discardableResult
    public func goToEntry(offset: Int) -> Bool {
        guard offset != 0, let id = browserID, let shim = runtime.shim,
              runtime.forkAPIVersion >= Self.backForwardListForkAPI,
              let offset = Int32(exactly: offset) else { return false }
        return shim.tabGoToEntry(id, offset) == 1
    }
}
