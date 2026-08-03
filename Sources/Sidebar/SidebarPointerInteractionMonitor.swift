import AppKit

@MainActor
final class SidebarPointerEventHostView: NSView {
    var onResolve: (@MainActor (NSView) -> Void)?
    var onDismantle: (@MainActor (NSView) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolve()
    }

    func resolve() {
        onResolve?(self)
    }
}
