import AppKit

/// Web Inspector visibility through WebKit's private `_inspector` object
/// (the toolbar's DevTools button shows it). False when WebKit lacks it.
extension WebKitTab {
    public var isInspectorVisible: Bool {
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector),
              let inspector = webView.perform(selector)?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: NSSelectorFromString("isVisible")) else { return false }
        return inspector.value(forKey: "visible") as? Bool ?? false
    }
}
