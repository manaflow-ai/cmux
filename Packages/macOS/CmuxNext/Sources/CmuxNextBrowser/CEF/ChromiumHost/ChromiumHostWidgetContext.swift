import CoreGraphics

// Hosted widgets (plans/cmux-next/chrome-parity/p01-process.md 3.3, task 066): every
// Chromium Views widget with a WebContents that is not a tab's page (an extension popup,
// the side panel, DevTools, a chrome.windows popup, an InitAsPopup page popup such as a
// date picker or a `<datalist>` list) gets a Core Animation context of its own in the host
// (fork task 173). cmux shows that context in a ChromiumHostPageView, in a cmux panel or a
// cmux pane view (``ChromiumHostWidgetHost``), and sends its input to the host as it does a
// page's. Chrome splits the same widgets between the browser process and the out-of-process
// view the same way: `RenderWidgetHostNSViewBridge::InitAsPopup` and `PopupWindowMac`
// (content/app_shim_remote_cocoa/render_widget_host_ns_view_bridge.mm, popup_window_mac.mm)
// make the popup's window where its view lives, and `NativeWidgetNSWindowBridge`
// (components/remote_cocoa/app_shim/native_widget_ns_window_bridge.mm) places every Views
// widget's window from bounds the browser sends.

/// A widget of WIDGET_CONTEXT, the host's id for it.
nonisolated struct ChromiumHostWidgetID: Hashable, Sendable {
    var rawValue: Int32
}

/// What a hosted widget is, which decides where cmux shows it.
nonisolated enum ChromiumHostWidgetKind: Int32, Sendable, CaseIterable {
    /// An extension action's popup page (`ExtensionPopup`).
    case extensionPopup = 1
    /// The side panel's page (`SidePanel` WebView), inside its owner's page.
    case sidePanel = 2
    /// A docked DevTools frontend: owner is the inspected page.
    case devTools = 3
    /// An undocked DevTools frontend in a window of its own: owner is the inspected page.
    case devToolsWindow = 4
    /// A chrome.windows.create popup window: owner is the popup's own tab.
    case popupWindow = 5
    /// An InitAsPopup page popup (date and time pickers, `<datalist>` suggestions): owner is its page.
    case pagePopup = 6

    /// Where cmux shows a widget.
    nonisolated enum Placement: Equatable, Sendable {
        /// A borderless cmux panel at the widget's bounds, a child of its owner's window.
        /// `takesKey`: the panel becomes key (an extension popup takes typing; a page popup
        /// leaves the keys with its page, whose renderer routes them, as Chrome's page popups do).
        case anchored(takesKey: Bool)
        /// A titled cmux window the person moves, resizes and closes.
        case window
        /// Fills a container cmux lays out (``ChromiumHostWidgetHost/place(_:owner:in:)``):
        /// cmux decides the rect and the host follows its geometry.
        case fill
        /// At the widget's bounds inside a container (its owner's page): the host decides the rect.
        case inPage

        /// cmux decides where it is, so its geometry goes to the host.
        var reportsGeometry: Bool {
            switch self {
            case .window, .fill: true
            case .anchored, .inPage: false
            }
        }
    }

    /// The kind's name in `debug.cef` `host_widgets` (chromium-host-bench.py `--native-ui`).
    var name: String {
        switch self {
        case .extensionPopup: "extension_popup"
        case .sidePanel: "side_panel"
        case .devTools: "devtools"
        case .devToolsWindow: "devtools_window"
        case .popupWindow: "popup_window"
        case .pagePopup: "page_popup"
        }
    }

    var placement: Placement {
        switch self {
        case .extensionPopup: .anchored(takesKey: true)
        case .pagePopup: .anchored(takesKey: false)
        case .devToolsWindow: .window
        case .devTools, .popupWindow: .fill
        case .sidePanel: .inPage
        }
    }
}

/// One WIDGET_CONTEXT: the widget, its owner, the context that shows it and where the host put it.
nonisolated struct ChromiumHostWidgetContext: Equatable, Sendable {
    var widget: ChromiumHostWidgetID
    var kind: ChromiumHostWidgetKind
    /// The owner's browser id (``ChromiumHostWidgetKind`` names which page that is).
    var owner: Int32
    /// The widget's CAContext id; 0 while it has no pixels.
    var contextID: UInt32
    /// DIPs from the primary display's top-left, as Chromium reports widget bounds; the
    /// side panel's (``ChromiumHostWidgetKind/Placement/inPage``) from its page's top-left.
    var bounds: CGRect
    /// The widget's title (an undocked DevTools window's), empty for the others.
    var title: String

    init(widget: ChromiumHostWidgetID, kind: ChromiumHostWidgetKind, owner: Int32, contextID: UInt32,
         bounds: CGRect, title: String = "") {
        self.widget = widget
        self.kind = kind
        self.owner = owner
        self.contextID = contextID
        self.bounds = bounds
        self.title = title
    }

    /// Decodes CMUX_SHIM_WIDGET_CONTEXT (`browser`, `request`, `a`, `s1`, `s2` of the shim
    /// event, plans/cmux-next/chromium-host-ops.json); nil for a field out of range, which
    /// then changes nothing.
    init?(owner: Int32, request: Int32, a: Int64, s1: String, s2: String) {
        let numbers = s1.split(separator: ",", omittingEmptySubsequences: false).map { Int32($0, radix: 10) }
        guard request != 0, let kind = ChromiumHostWidgetKind(rawValue: Int32(truncatingIfNeeded: a >> 32)),
              numbers.count == 4, let x = numbers[0], let y = numbers[1], let width = numbers[2], let height = numbers[3],
              width > 0, height > 0 else { return nil }
        self.init(widget: ChromiumHostWidgetID(rawValue: request), kind: kind, owner: owner,
                  contextID: UInt32(truncatingIfNeeded: a),
                  bounds: CGRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height)), title: s2)
    }

    /// ``bounds`` as an AppKit screen rect (origin at the primary display's bottom left);
    /// `primaryTop` is the primary display's frame maxY.
    func screenFrame(primaryTop: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: primaryTop - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}
