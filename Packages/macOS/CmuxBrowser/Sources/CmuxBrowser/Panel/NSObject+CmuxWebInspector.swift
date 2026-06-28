public import Foundation

extension NSObject {
    /// Whether this object is one of WebKit's Web Inspector objects, detected by
    /// matching its runtime class name (both the Swift-described and the
    /// Objective-C `NSStringFromClass` form) against the inspector class-name
    /// substrings. Used by the browser window portal and panels to recognize the
    /// inspector views WebKit injects into a hosted page's responder/view tree.
    public var isCmuxWebInspectorObject: Bool {
        String(describing: type(of: self)).isCmuxWebInspectorClassName ||
            NSStringFromClass(type(of: self)).isCmuxWebInspectorClassName
    }
}
