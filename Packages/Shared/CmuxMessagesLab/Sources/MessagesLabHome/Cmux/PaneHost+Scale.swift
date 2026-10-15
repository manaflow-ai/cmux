import AppKit

// cmux: MessagesLab 258b385 (cx-3cb view-scale). Each Home pane's MessagesWindowView renders at its own scale
// (MessagesWindowView.renderScale): its rows, masks, snaps, compose bar, header, morph and overlays. Home has one
// window view per pane and tab, so every pane follows its own window, as Host.swift's followWindowScale does.

extension ChatController {
    /// This pane's transcript follows its own window's backing scale. Called when the pane goes into a window
    /// (windowChanged), when its window view is installed, when it is shown again (HostView.viewDidUnhide) and on
    /// every backing scale change (HostView.viewDidChangeBackingProperties). setRenderScale is called every time,
    /// never skipped by a compare with the process value (`Fixture.renderScale`, which another pane may have set
    /// already): its own guard is the view's renderScale. The host's layer trees, the picker and the video layers
    /// follow only when this view's scale changed.
    func followWindowScale() {
        guard let demo, let s = host.window?.backingScaleFactor, s > 0 else { return }
        let changed = s != demo.renderScale
        if changed {
            DisplayScale.current = s  // the process fallback (code with no view), as Host.swift
            CATransaction.begin(); CATransaction.setDisableActions(true)
            func walk(_ l: CALayer) { if l.delegate is NSView { return }; l.contentsScale = s; l.sublayers?.forEach(walk); l.mask.map(walk) }
            // cmux: threadHost holds the window view's thread layer (PaneHost+ThreadLayer.swift), out of `below`'s tree.
            // Its delegate is the vendored UIView shim, an NSObject (not an NSView), so the walk enters it.
            [host.below.root, host.threadHost.root, host.headerVeil.root, host.morphHost.root, host.composeHost.root, host.above.root].forEach(walk)
            CATransaction.commit()
            ScaleKeeper.shared.setNeedsApply()
        }
        demo.setRenderScale(s)
        guard changed else { return }
        demo.moveToWindowRecursively()
        picker?.rescale()
        intents?.rowsPlaced()  // the video layers follow the rows' new snap (82ccac1)
    }
}

extension ChatController {
    /// Another display: new bitmaps draw in its colour space (no conversion at commit). One process-wide colour space
    /// (`DisplayScale.colorSpace`). cmux 258b385: the row bitmap cache is not dropped and `setInactive` is not toggled
    /// (both emptied every pane's cache and redrew every visible row: a window back on its 2x display showed its 1x
    /// bitmaps until the off-main ones landed, depending on whether this notification came before or after the
    /// backing scale change). Dropping only this pane's rows would race the same way (at the scale it goes back to).
    /// A cached bitmap carries its own colour space, so a bitmap of the old space still shows the right colours; the
    /// next drawing of a row uses the new space.
    func windowDidChangeScreen() {
        guard let cs = window?.screen?.colorSpace?.cgColorSpace, cs != DisplayScale.colorSpace, let demo else { return }
        DisplayScale.colorSpace = cs
        // MessagesLab 7518134: the palette glyphs are drawn again in the new colour space now, not
        // inside the next menu's open on main.
        MenuGlyphs.removeAll()
        RunLoop.main.perform(inModes: [.default]) { MenuGlyphs.warm() }
        demo.compose.rescale()
    }
}

/// Keeps every content-less layer of the hosted trees at its pane's scale.
/// Layers the shared code creates without a contentsScale (typing dots, masks)
/// would otherwise keep Core Animation's default of 1. A layer with contents
/// is left alone: whoever rasterized it set its scale (and the resolution
/// audit checks it). NSView-managed layers belong to AppKit. Runs when the
/// main run loop goes idle; a walk is a few dozen pointer reads.
final class ScaleKeeper {
    static let shared = ScaleKeeper()
    /// cmux: every hosted Home tab (weak: a closed tab drops out), each walked at its own window view's
    /// renderScale (MessagesLab 258b385: two panes can be at two scales).
    private let hosts = NSHashTable<HostView>.weakObjects()
    func register(_ host: HostView) { hosts.add(host); dirty = true }
    private var observer: CFRunLoopObserver?
    /// cmux: walk only after something could have added layers (an engine
    /// change, a scroll, a window or display change). Host.swift walked on
    /// every main run loop pass: 7% of the main thread in the tab-switch
    /// bench, with Home hidden too.
    private var dirty = true
    func setNeedsApply() { dirty = true }

    func start() {
        guard observer == nil else { return }
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            guard let self, self.dirty else { return }
            self.apply()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        observer = o
        apply()
    }

    func apply() {
        dirty = false
        var changed = false
        func walk(_ l: CALayer, _ s: CGFloat) {
            if l.contentsScale != s, l.contents == nil, !(l.delegate is NSView) {
                if !changed { CATransaction.begin(); CATransaction.setDisableActions(true); changed = true }
                l.contentsScale = s
            }
            if let m = l.mask { walk(m, s) }
            l.sublayers?.forEach { walk($0, s) }
        }
        for host in hosts.allObjects {
            let s = host.demo?.renderScale ?? DisplayScale.current
            [host.below.root, host.threadHost.root, host.headerVeil.root, host.morphHost.root, host.composeHost.root, host.above.root].forEach { walk($0, s) }
        }
        if changed { CATransaction.commit() }
    }
}
