public import WebKit
public import AppKit

/// WebKit Web Inspector SPI accessors.
///
/// cmux drives Web Inspector through WebKit's private `_inspector` object because
/// the deployable SDK surface does not expose a stable open/close API. These
/// accessors reach the inspector controller and its frontend web view through the
/// same auditable `perform(_:)`-on-selector path used by the teardown service so
/// WebKit unregisters its inspector window observers before AppKit close cascades.
extension WKWebView {
    /// The WebKit `_inspector` controller object for this web view, or `nil` when
    /// the web view does not respond to the SPI selector.
    public func cmuxInspectorObject() -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard responds(to: selector),
              let inspector = perform(selector)?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        return inspector
    }

    /// The inspector's frontend web view (the inspector UI host), or `nil` when no
    /// inspector controller exists or it exposes no frontend web view.
    public func cmuxInspectorFrontendWebView() -> WKWebView? {
        guard let inspector = cmuxInspectorObject() else { return nil }
        let selector = NSSelectorFromString("inspectorWebView")
        guard inspector.responds(to: selector),
              let inspectorWebView = inspector.perform(selector)?.takeUnretainedValue() as? WKWebView else {
            return nil
        }
        return inspectorWebView
    }
}

extension NSObject {
    /// Whether this object is (or is part of) a WebKit Web Inspector frontend,
    /// detected by class-name shape. Used to exclude inspector chrome from web-view
    /// collection and teardown so cmux never tears down the inspector's own UI.
    public var cmuxIsWebInspectorObject: Bool {
        String(describing: type(of: self)).cmuxIsWebInspectorClassName
            || NSStringFromClass(type(of: self)).cmuxIsWebInspectorClassName
    }
}

extension String {
    /// Whether a class name belongs to WebKit's Web Inspector implementation.
    var cmuxIsWebInspectorClassName: Bool {
        contains("WKInspector") || contains("WebInspector")
    }
}
