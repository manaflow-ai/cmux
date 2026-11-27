import AppKit

extension WebKitTab {
    /// Whether Web Inspector is shown (observable; `WebKitInspectorWatch`).
    public var isInspectorVisible: Bool { inspectorWatch.isVisible }
}
