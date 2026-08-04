import AppKit

extension WindowBrowserPortal {
    static func hasVisibleInspectorView(in root: NSView) -> Bool {
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if cmuxIsWebInspectorObject(current),
               !current.isHidden,
               current.alphaValue > 0,
               current.frame.width > 1,
               current.frame.height > 1 {
                return true
            }
            stack.append(contentsOf: current.subviews)
        }
        return false
    }
}
