public import Foundation

extension String {
    /// Whether this class name string belongs to WebKit's Web Inspector, matched
    /// by the private class-name substrings WebKit uses (`WKInspector*` and
    /// `WebInspector*`). Used to detect inspector views/objects that WebKit
    /// inserts into a hosted page's view tree.
    public var isCmuxWebInspectorClassName: Bool {
        contains("WKInspector") || contains("WebInspector")
    }
}
