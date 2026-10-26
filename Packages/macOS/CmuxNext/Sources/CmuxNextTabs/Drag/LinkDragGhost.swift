package import AppKit
package import CmuxNextDesign

/// The pill that follows the pointer while a link is dragged out of a chat (``LinkDragSession``):
/// the link's host and path on glass, in a borderless panel that ignores the mouse and floats
/// above every window. It only moves; the layout's own drop preview shows where the link lands.
package final class LinkDragGhost {
    package let panel: NSPanel
    private static let offset = CGPoint(x: 14, y: 10)
    private static let maxWidth: CGFloat = 320

    package init(title: String) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: TypeScale.body, weight: TypeScale.emphasis)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        let height: CGFloat = 28
        let width = min(Self.maxWidth, ceil(label.intrinsicContentSize.width) + Metrics.space2 * 3)
        let size = CGSize(width: width, height: height)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        ThemeScope.app.adopt(panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let glass = Glass.makePanel(style: .regular, cornerRadius: height / 2)
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.samplesBehindWindow = true
        glass.frame = NSRect(origin: .zero, size: size)
        glass.autoresizingMask = [.width, .height]
        label.frame = NSRect(x: Metrics.space2 * 1.5, y: (height - label.intrinsicContentSize.height) / 2,
                             width: width - Metrics.space2 * 3, height: label.intrinsicContentSize.height)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.addSubview(glass)
        root.addSubview(label)
        panel.contentView = root
    }

    /// Puts the pill just right of and below the pointer at `screenPoint` (y up).
    package func move(to screenPoint: CGPoint) {
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: screenPoint.x + Self.offset.x, y: screenPoint.y - Self.offset.y - size.height))
    }

    package func show(at screenPoint: CGPoint) {
        move(to: screenPoint)
        panel.orderFrontRegardless()
    }

    package func close() {
        panel.orderOut(nil)
        panel.close()
    }
}
