import AppKit
import CmuxNextDesign

/// The icon picker's floating panel: a child of the cmux window it opens over,
/// beside its anchor (the workspace's sidebar row), with the system popover
/// material. It takes the keys only while the app is active (``ActiveAppKeyPanel``),
/// so a picker opened by a socket or CLI call never captures another app's typing.
/// A panel, not an NSPopover: a transient popover closed itself when the app was
/// not active (nxdog34), and `debug.popups` lists panels.
@MainActor
final class IconPickerPanel: ActiveAppKeyPanel {
    /// Closes the picker without a pick: the panel lost the keys or another window took them.
    var onDismiss: (() -> Void)?

    init(content: NSView, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 12
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        content.frame = material.bounds
        content.autoresizingMask = [.width, .height]
        material.addSubview(content)
        contentView = material
        onKeyElsewhere = { [weak self] in self?.onDismiss?() }
    }

    /// A click outside (another window took the keys) closes the picker without a pick.
    override func resignKey() {
        super.resignKey()
        onDismiss?()
    }

    /// The panel frame (screen coordinates) for an anchor rect (screen coordinates): to the
    /// right of the anchor, top-aligned with it, kept inside `visible` (the screen's visible frame).
    static func frame(size: NSSize, anchor: NSRect, visible: NSRect?) -> NSRect {
        var frame = NSRect(x: anchor.maxX + 8, y: anchor.maxY - size.height, width: size.width, height: size.height)
        guard let visible else { return frame }
        if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, anchor.minX - 8 - size.width) }
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        return frame
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}
