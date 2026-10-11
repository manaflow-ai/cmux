import CoreGraphics
import Foundation

/// Chromium's side panel as cmux draws its header (fork API 13): which
/// controls Chromium's own header shows and where that header is. cmux draws
/// the header in theme colors over Chromium's header area and runs each
/// control through Chromium's button (`cmux_shim_side_panel_press`), so
/// pinning, the more-info menu and closing keep Chromium's behavior.
nonisolated struct CEFSidePanelState: Equatable, Sendable {
    enum Control: String, Sendable {
        case close
        case pin
        case openInNewTab = "open_in_new_tab"
        case moreInfo = "more_info"
    }

    var title: String
    /// PNG data of the panel's icon (2x), when it has one.
    var icon: Data?
    var showsPin: Bool
    var isPinned: Bool
    var showsOpenInNewTab: Bool
    var showsMoreInfo: Bool
    /// Chromium's own header buttons still in the keyboard focus order
    /// (fork API 14 reports it; 0 once cmux draws the header). nil on older forks.
    var chromiumFocusableControls: Int?
    /// Chromium's header in the page window: DIPs from its top-left.
    var header: CGRect

    /// Decodes `cmux_side_panel_state`; nil when the panel is closed or the
    /// JSON has no header.
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["open"] as? Bool == true,
              let rect = object["header"] as? [String: Any],
              let width = rect["width"] as? Double, let height = rect["height"] as? Double,
              width > 0, height > 0 else { return nil }
        title = object["title"] as? String ?? ""
        icon = (object["icon_png"] as? String).flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0) }
        showsPin = object["pin_visible"] as? Bool ?? false
        isPinned = object["pinned"] as? Bool ?? false
        showsOpenInNewTab = object["open_in_new_tab"] as? Bool ?? false
        showsMoreInfo = object["more_info"] as? Bool ?? false
        chromiumFocusableControls = object["focusable_controls"] as? Int
        header = CGRect(x: rect["x"] as? Double ?? 0, y: rect["y"] as? Double ?? 0, width: width, height: height)
    }

    /// The header's frame in a non-flipped view where the page window
    /// covers `page`.
    func headerFrame(inPage page: CGRect) -> CGRect {
        CGRect(x: page.minX + header.minX, y: page.maxY - header.maxY, width: header.width, height: header.height)
    }
}
