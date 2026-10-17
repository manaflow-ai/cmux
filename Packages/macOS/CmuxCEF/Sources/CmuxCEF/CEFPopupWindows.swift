public import CoreGraphics
import Foundation

/// When cmux turns on the fork's popup windows (`chrome.windows.create({type:
/// "popup"})`, which password managers and sign-in extensions use). Fork API
/// 11 has them, but there the attached window never shows and its
/// CMUX_POPUP_WINDOW_CREATED window id is not the id chrome.windows returns;
/// fork API 13 fixed both. Older forks keep moving the popup's tab into a
/// pane, so the window id the extension got stops working.
///
/// Reference: cmux Next `CmuxNextBrowser/CEF/CEFPaneHost+PopupWindows.swift`.
public enum CEFPopupWindows {
    public static let minimumForkAPI: Int32 = 13

    public static func isEnabled(forkAPIVersion: Int32) -> Bool { forkAPIVersion >= minimumForkAPI }

    /// True when `bounds` (a CMUX_POPUP_WINDOW_BOUNDS report) is only the
    /// attached window following its host view (`hostFrame`, the view in
    /// screen DIPs from the primary display's top-left). Feeding that back
    /// would resize the popup window by its title bar each time.
    public static func isOwnPlacement(_ bounds: CGRect, hostFrame: CGRect?) -> Bool {
        guard let hostFrame else { return false }
        return abs(bounds.minX - hostFrame.minX) <= 1 && abs(bounds.minY - hostFrame.minY) <= 1
            && abs(bounds.width - hostFrame.width) <= 1 && abs(bounds.height - hostFrame.height) <= 1
    }

    /// The current entry's URL and title of `cmux_shim_tab_navigation_entries`
    /// JSON (`{"current": index, "entries": [{"url", "title"}]}`).
    static func currentEntry(navigationEntriesJSON json: String) -> (url: URL, title: String)? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["entries"] as? [[String: Any]],
              let index = object["current"] as? Int, entries.indices.contains(index),
              let url = (entries[index]["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return (url, entries[index]["title"] as? String ?? "")
    }
}
