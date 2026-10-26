/// Chromium's native UI on a page whose Cocoa view is a subview of the pane's ``CEFHostView``
/// (p03-rendering Track B, tasks 044-046). Chrome's page is an ordinary subview of its window
/// (`content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm`), so most of its native UI comes
/// from that view and needs nothing from cmux. What Chromium hangs on the page's own window (a
/// `views::Widget` child of the Browser's widget) cannot show while that window never orders in: the
/// fork orders it in for the widget's lifetime and says so (``CEFForkTabEvent/pageWindowWidget``,
/// ``CEFPageWindowWidgets``).
///
/// `cef-native-ui-live.py` checks each kind on the fleet, in the order of ``allCases``, and its row
/// names are ``checkName``. No fork sends ``CEFForkTabEvent/pageWindowWidget`` yet, and no fleet run has
/// checked a ``route`` (`plans/cmux-next/chrome-parity/p03-rendering-046-native-ui.md`, Status).
nonisolated enum CEFNativeWidget: Int, CaseIterable, Sendable {
    /// `<select>` popups.
    case selectPopup = 0
    /// The page's context menu.
    case contextMenu = 1
    /// Autofill, password and `<datalist>` dropdowns.
    case autofill = 2
    /// `<input type=color>`.
    case colorPicker = 3
    /// `<input type=date>` and the other date and time pickers.
    case datePicker = 4
    /// Print preview (`window.print()`, Cmd-P in the page).
    case printPreview = 5
    /// Marked text of an input method (Japanese, Korean, dead keys, the emoji picker).
    case inputMethod = 6
    /// Files dragged in from another app.
    case fileDropIn = 7
    /// A link or an image dragged out of the page.
    case linkDragOut = 8
    /// The page's accessibility tree (VoiceOver, automation drivers).
    case accessibility = 9
    /// `title` tooltips.
    case tooltip = 10
    /// CSS cursors.
    case cursor = 11
    /// A `views::Widget` child of the page window the fork reports by no other kind.
    case otherPageWidget = 12

    /// Where the widget should show on an attached page, read from ``chromiumSource``. A fleet run of
    /// `cef-native-ui-live.py` on a Track B build confirms or changes it.
    var route: CEFNativeWidgetRoute {
        switch self {
        case .selectPopup, .colorPicker, .datePicker, .inputMethod, .linkDragOut, .accessibility, .tooltip, .cursor:
            .chromiumView
        case .contextMenu, .fileDropIn:
            .host
        case .autofill, .printPreview, .otherPageWidget:
            .pageWindow
        }
    }

    /// The Chromium code that shows it on macOS, which decides the route.
    var chromiumSource: String {
        switch self {
        case .selectPopup:
            // PopupMenuHelper runs WebMenuRunner's NSMenu in the page's view, in whatever window holds it.
            "content/app_shim_remote_cocoa/web_menu_runner_mac.mm"
        case .contextMenu:
            // cmux shows its own menu for CONTEXT_MENU in the tab's content view (CEFRuntime+ContextMenu).
            "chrome/browser/ui/cocoa/renderer_context_menu/render_view_context_menu_mac_cocoa.mm"
        case .autofill:
            // PopupViewViews is a views::Widget whose parent is the Browser's widget: the page window.
            "chrome/browser/ui/views/autofill/popup/popup_view_views.cc"
        case .colorPicker:
            // The shared NSColorPanel, anchored to nothing.
            "components/remote_cocoa/app_shim/color_panel_bridge.mm"
        case .datePicker:
            // A popup RenderWidgetHostView: its own NSWindow at the screen point the renderer gives from the page's view.
            "content/app_shim_remote_cocoa/popup_window_mac.mm"
        case .printPreview:
            // A web-modal dialog on the Browser's widget: the page window.
            "chrome/browser/ui/views/constrained_window_views.cc"
        case .inputMethod:
            // RenderWidgetHostViewCocoa is the NSTextInputClient; cmux adds none (rule K1).
            "content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm"
        case .fileDropIn:
            // Chrome's drag destination is the WebContentsViewCocoa, which stays in the page window: the host
            // view's CEFFileDragRelay takes the drag and replays it, with its scope rules.
            "content/app_shim_remote_cocoa/web_drag_dest_mac.mm"
        case .linkDragOut:
            // The drag session starts from the page's view with the mouse-down event of the cmux window.
            "content/app_shim_remote_cocoa/web_contents_view_cocoa.mm"
        case .accessibility:
            // The page's view returns its BrowserAccessibilityCocoa root as its accessibility child.
            "content/browser/accessibility/browser_accessibility_cocoa.mm"
        case .tooltip:
            // setToolTipAtMousePoint: on the page's view.
            "content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm"
        case .cursor:
            // updateCursor: on the page's view, inside its own tracking area.
            "content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm"
        case .otherPageWidget:
            "ui/views/widget/native_widget_mac.mm"
        }
    }

    /// The row of `cef-native-ui-live.py` that checks it; `otherPageWidget` has none (no page opens one on purpose).
    var checkName: String? {
        switch self {
        case .selectPopup: "select"
        case .contextMenu: "context-menu"
        case .autofill: "autofill"
        case .colorPicker: "color-picker"
        case .datePicker: "date-picker"
        case .printPreview: "print-preview"
        case .inputMethod: "ime"
        case .fileDropIn: "file-drop-in"
        case .linkDragOut: "link-drag-out"
        case .accessibility: "accessibility"
        case .tooltip: "tooltip"
        case .cursor: "cursor"
        case .otherPageWidget: nil
        }
    }
}

/// Where a ``CEFNativeWidget`` shows on an attached page.
nonisolated enum CEFNativeWidgetRoute: Equatable, Sendable {
    /// Chromium's own view in the cmux window shows it; cmux adds nothing.
    case chromiumView
    /// cmux shows it from the host view (its context menu, its file drop relay), as before Track B.
    case host
    /// Per-widget fallback: while the widget is open the page window orders in over the host view,
    /// transparent and ignoring the mouse, so the widget (its own child window) shows and the page's pixels
    /// and clicks stay in the attached view (``CEFPageWindowWidgets``).
    case pageWindow
}

/// One ``CEFForkTabEvent/pageWindowWidget`` report: `value` is the widget's kind shifted left by one, with
/// bit 0 set when the page window orders in for it and clear when it orders out.
nonisolated struct CEFPageWindowWidgetEvent: Equatable, Sendable {
    /// The fork's kind: a ``CEFNativeWidget`` raw value, or a kind a newer fork added. It stays raw, so two
    /// unknown kinds stay two widgets in ``CEFPageWindowWidgets``.
    var kind: Int
    var shown: Bool

    init(widget: CEFNativeWidget, shown: Bool) {
        kind = widget.rawValue
        self.shown = shown
    }

    init(value: Int) {
        kind = value >> 1
        shown = value & 1 != 0
    }

    /// A kind this app does not know yet is still a widget over the page window (``CEFNativeWidget/otherPageWidget``).
    var widget: CEFNativeWidget { CEFNativeWidget(rawValue: kind) ?? .otherPageWidget }

    /// The tab event's value for this report (fork tests and fakes).
    var value: Int { kind << 1 | (shown ? 1 : 0) }
}
