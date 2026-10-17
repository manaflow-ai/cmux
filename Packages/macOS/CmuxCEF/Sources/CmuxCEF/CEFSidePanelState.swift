public import CoreGraphics
public import Foundation

/// Chromium's side panel (`chrome.sidePanel`) as cmux draws its header (fork
/// API 13): which controls Chromium's own header shows and where that header
/// is. The panel itself stays Chromium's, inside the page window; the shim
/// watches every window's side panel (`cmux_side_panel_watch`), which takes
/// Chromium's header buttons out of the focus order and the accessibility
/// tree, so cmux draws the header over Chromium's header area and runs each
/// control through Chromium's button (`cmux_shim_side_panel_press`).
///
/// Reference: cmux Next `CmuxNextBrowser/CEF/CEFSidePanelState.swift`.
public struct CEFSidePanelState: Equatable, Sendable {
    public enum Control: String, Sendable, CaseIterable {
        case close
        case pin
        case openInNewTab = "open_in_new_tab"
        case moreInfo = "more_info"
    }

    public static let minimumForkAPI: Int32 = 13

    public var title: String
    /// PNG data of the panel's icon (2x), when it has one.
    public var icon: Data?
    public var showsPin: Bool
    public var isPinned: Bool
    public var showsOpenInNewTab: Bool
    public var showsMoreInfo: Bool
    /// Chromium's own header buttons still in the keyboard focus order (fork
    /// API 14; 0 once cmux draws the header). nil on older forks.
    public var chromiumFocusableControls: Int?
    /// Chromium's header in the page window: DIPs from its top-left.
    public var header: CGRect

    /// Decodes `cmux_side_panel_state`; nil when the panel is closed or the
    /// JSON has no header.
    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["open"] as? Bool == true,
              let rect = object["header"] as? [String: Any],
              let width = (rect["width"] as? NSNumber)?.doubleValue,
              let height = (rect["height"] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        title = object["title"] as? String ?? ""
        icon = (object["icon_png"] as? String).flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0) }
        showsPin = object["pin_visible"] as? Bool ?? false
        isPinned = object["pinned"] as? Bool ?? false
        showsOpenInNewTab = object["open_in_new_tab"] as? Bool ?? false
        showsMoreInfo = object["more_info"] as? Bool ?? false
        chromiumFocusableControls = object["focusable_controls"] as? Int
        header = CGRect(x: (rect["x"] as? NSNumber)?.doubleValue ?? 0, y: (rect["y"] as? NSNumber)?.doubleValue ?? 0,
                        width: width, height: height)
    }

    /// The header's frame in a non-flipped view whose bounds the page window
    /// covers (`CEFHostView`).
    public func headerFrame(inPage page: CGRect) -> CGRect {
        CGRect(x: page.minX + header.minX, y: page.maxY - header.maxY, width: header.width, height: header.height)
    }

    /// The controls the header shows, in Chromium's order.
    public var visibleControls: [Control] {
        [(showsPin, Control.pin), (showsOpenInNewTab, .openInNewTab), (showsMoreInfo, .moreInfo), (true, .close)]
            .filter(\.0).map(\.1)
    }
}
