public import AppKit

/// Host mode's widgets (task 066, feature `chromiumHostWidgets`): the Chromium host's extension
/// popups, side panel, DevTools, popup windows and page popups in cmux panels and panes.
extension CEFRuntime {
    /// The host's widgets in cmux; nil in process, with the feature off, before the start and
    /// with a host whose shim has no widget ops.
    var widgetHost: ChromiumHostWidgetHost? { hostStart?.widgetHost }

    /// Host mode, at the start: shows the host's widgets over this runtime's tabs when the source
    /// asks for them (``CEFHostStart/showsWidgets``) and the host's shim has every widget op.
    func showHostWidgets(_ shim: CEFShimLibrary) {
        guard let hostStart, hostStart.showsWidgets, shim.widgets.isComplete else { return }
        showHostWidgets(on: CEFShimWidgetWire(ops: shim.widgets))
    }

    /// Shows the host's widgets over this runtime's tabs, their input and geometry going to `wire`.
    func showHostWidgets(on wire: any ChromiumHostWidgetWire) {
        hostStart?.widgetHost = ChromiumHostWidgetHost(wire: wire, ownerWindow: { [weak self] browser in
            self?.tabsByBrowser[browser]?.host.hostView.window
        })
    }
}

/// One widget the host shows in cmux, for `debug.cef` `host_widgets` (chromium-host-bench.py `--native-ui`).
public struct CEFHostWidgetReport: Equatable, Sendable {
    /// `extension_popup`, `side_panel`, `devtools`, `devtools_window`, `popup_window` or `page_popup`.
    public let kind: String
    public let widget: Int32
    /// The browser the widget belongs to.
    public let owner: Int32
    public let contextID: UInt32
    /// Its view is in a window.
    public let shown: Bool
    /// Its view's screen rect (AppKit origin), zero while not shown.
    public let screenFrame: CGRect
}

extension CEFEngine {
    /// The host's widgets shown now; nil without a widget host (in process, or the feature off).
    public var hostWidgets: [CEFHostWidgetReport]? {
        CEFRuntime.shared.widgetHost?.diagnostics.map {
            CEFHostWidgetReport(kind: $0.kind.name, widget: $0.widget.rawValue, owner: $0.owner, contextID: $0.contextID,
                                shown: $0.shown, screenFrame: $0.screenFrame)
        }
    }
}
