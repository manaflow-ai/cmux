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
        // The video layers follow the rows' new snap (82ccac1) after the scale's display change has installed them.
        if applyWindowScale() { intents?.rowsPlaced() }
    }

    /// followWindowScale without the video placement: true when this view's scale changed. Inside an outer
    /// `MessagesWindowView.displayChange` (followDisplay) the rows snap at the end of that pass, so the caller places
    /// the video layers after it.
    @discardableResult private func applyWindowScale() -> Bool {
        guard let demo, let s = host.window?.backingScaleFactor, s > 0 else { return false }
        let changed = s != demo.renderScale
        if changed {
            DisplayScale.current = s  // the process fallback (code with no view), as Host.swift
            CATransaction.begin(); CATransaction.setDisableActions(true)
            func walk(_ l: CALayer) { if l.delegate is NSView { return }; l.contentsScale = s; l.sublayers?.forEach(walk); l.mask.map(walk) }
            [host.below.root, host.morphHost.root, host.composeHost.root, host.above.root].forEach(walk)
            CATransaction.commit()
            ScaleKeeper.shared.setNeedsApply()
        }
        demo.setRenderScale(s)
        guard changed else { return false }
        demo.moveToWindowRecursively()
        picker?.rescale()
        return true
    }
}

extension ChatController {
    /// A move to another display (MessagesLab 1674e3f, cx-3cb scale-redraw; Home handler rule): its colour space
    /// (process-wide) and this pane's backing scale in one display change (MessagesWindowView.displayChange), so the
    /// visible rows of every view draw once, at the new scale and in the new colour space, in this commit: the first
    /// frame after the move shows no row at the old scale or colour space. AppKit reports the move twice
    /// (viewDidChangeBackingProperties, NSWindow.didChangeScreenNotification), in either order: the first call does
    /// both, the second finds nothing to do. `backingChanged` (viewDidChangeBackingProperties, also sent for a new
    /// display profile on the same screen): nothing when neither the scale nor the screen's colour space differs.
    /// Never `RowBitmaps.shared.removeAll()` and never a `setInactive` toggle here: cached bitmaps are keyed by scale
    /// and colour space (a move back finds them), and both dropped every pane's rows (258b385).
    func followDisplay(backingChanged: Bool = false) {
        if backingChanged, let demo, host.window?.backingScaleFactor == demo.renderScale,
           window?.screen?.colorSpace?.cgColorSpace.map({ $0 == DisplayScale.colorSpace }) ?? true { return }
        var scaled = false
        MessagesWindowView.displayChange {
            followColorSpace()
            scaled = applyWindowScale()
        }
        // After the pass: the visible rows have their new snap now (a deferred refresh runs at the pass's end).
        if scaled { intents?.rowsPlaced() }
    }

    /// Another display: new bitmaps draw in its colour space (no conversion at commit). One process-wide colour space
    /// (`DisplayScale.colorSpace`). Only when the space changed: every live view's chrome, compose bar and visible
    /// rows draw again in it (MessagesWindowView.displayColorSpaceChanged), in the enclosing display change's pass.
    private func followColorSpace() {
        guard demo != nil, let cs = window?.screen?.colorSpace?.cgColorSpace, cs != DisplayScale.colorSpace else { return }
        DisplayScale.colorSpace = cs
        // MessagesLab 7518134: the palette glyphs are drawn again in the new colour space now, not
        // inside the next menu's open on main.
        MenuGlyphs.removeAll()
        RunLoop.main.perform(inModes: [.default]) { MenuGlyphs.warm() }
        MessagesWindowView.displayColorSpaceChanged()
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
            [host.below.root, host.morphHost.root, host.composeHost.root, host.above.root].forEach { walk($0, s) }
        }
        if changed { CATransaction.commit() }
    }
}
