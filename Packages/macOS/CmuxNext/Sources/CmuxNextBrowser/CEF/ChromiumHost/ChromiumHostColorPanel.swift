import AppKit
import CmuxNextWakeups

/// The panel a page's `<input type=color>` shows (``ChromiumHostChoosers``): the shared NSColorPanel in
/// the app, a recorder in tests. Colors are 0xAARRGGBB.
protocol ChromiumHostColorPanelDriving: AnyObject {
    /// Shows the panel with `color`; `onColor` gets each color the person picks, `onClose` the panel's close.
    func open(_ color: UInt32, onColor: @escaping (UInt32) -> Void, onClose: @escaping () -> Void)
    /// The page set the input's value: the panel shows it, with no `onColor`.
    func show(_ color: UInt32)
    /// The chooser ended on the page's side: the panel closes, with no `onClose`.
    func close()
}

/// Drives the shared NSColorPanel for one chooser at a time, as Chrome's ColorChooserMac does
/// (chrome/browser/ui/cocoa/color_chooser_mac.mm): alpha hidden (an `<input type=color>` has none),
/// continuous, so each change reaches the page as its `input` event, and the panel's close ends the
/// chooser. The panel is shared with cmux's own color wells, so its settings come back at the end.
final class ChromiumHostColorPanel: NSObject, ChromiumHostColorPanelDriving {
    private var onColor: ((UInt32) -> Void)?
    private var onClose: (() -> Void)?
    private var borrowed: (showsAlpha: Bool, isContinuous: Bool)?
    private var closeObserver: EventSubscription?
    /// Set while the panel shows a color the page set: the panel's own action for it is not the person's.
    private var settingColor = false

    func open(_ color: UInt32, onColor: @escaping (UInt32) -> Void, onClose: @escaping () -> Void) {
        let panel = NSColorPanel.shared
        if borrowed == nil { borrowed = (panel.showsAlpha, panel.isContinuous) }
        self.onColor = onColor
        self.onClose = onClose
        if closeObserver == nil {
            closeObserver = WindowEvents.of(panel).subscribe(NSWindow.willCloseNotification, owner: "ChromiumHostColorPanel") { [weak self] in
                self?.panelClosed()
            }
        }
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        show(color)
        panel.makeKeyAndOrderFront(nil)
    }

    func show(_ color: UInt32) {
        guard onColor != nil else { return }
        settingColor = true
        NSColorPanel.shared.color = Self.color(color)
        settingColor = false
    }

    func close() {
        guard onColor != nil else { return }
        release()
        NSColorPanel.shared.orderOut(nil)
    }

    private func panelClosed() {
        let closed = onClose
        release()
        closed?()
    }

    private func release() {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        if let borrowed {
            panel.showsAlpha = borrowed.showsAlpha
            panel.isContinuous = borrowed.isContinuous
        }
        borrowed = nil
        onColor = nil
        onClose = nil
        closeObserver = nil
    }

    @objc private func changed(_ sender: Any?) {
        guard !settingColor, let onColor else { return }
        onColor(Self.argb(NSColorPanel.shared.color))
    }

    /// 0xAARRGGBB as an sRGB color.
    static func color(_ argb: UInt32) -> NSColor {
        func channel(_ shift: UInt32) -> CGFloat { CGFloat((argb >> shift) & 0xFF) / 255 }
        return NSColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }

    /// The color in sRGB as 0xFFRRGGBB (opaque: the page's input has no alpha); black for a color with
    /// no sRGB form (a pattern).
    static func argb(_ color: NSColor) -> UInt32 {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0xFF00_0000 }
        func channel(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return 0xFF00_0000 | channel(srgb.redComponent) << 16 | channel(srgb.greenComponent) << 8 | channel(srgb.blueComponent)
    }
}
