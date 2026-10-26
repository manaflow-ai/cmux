public import AppKit
import CmuxNextInput

extension WindowOverlayHost {
    // MARK: Modal

    /// The overlay takes the keyboard (the panel becomes key, or in the window's
    /// top layer the window's first responder moves into it); Tab cycles inside
    /// the overlay (its key view loop holds only overlay views); the previous key
    /// window and first responder are kept for `endModal`.
    func beginModal(_ handle: OverlayHandle) {
        if !handles.dropLast().contains(where: { $0.options.isModal }) {
            restoreWindow = NSApp.keyWindow ?? window
            // A field editor stands in for its text field: keep the field (the editor moves between fields).
            let responder = (NSApp.keyWindow ?? window)?.firstResponder
            if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
                restoreResponder = field
                restoreSelection = editor.selectedRanges
            } else {
                restoreResponder = responder
                restoreSelection = nil
            }
            otherWindowTookKey = false
            modalLeftWindowUsable = false
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                                 queue: .main) { [weak self] note in
                let window = (note.object as AnyObject?).map(ObjectIdentifier.init)
                // main-proof: observer on queue: .main
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    // The overlay taking the keyboard back cancels a move. The overlay's own window
                    // becoming key is the app coming back to the front (dogfood 2026-10-08, C3),
                    // not a move: a click into it shows as a first responder change instead.
                    if let panel = self.madePanel, window == ObjectIdentifier(panel) {
                        self.otherWindowTookKey = false
                    } else if ![self.restoreWindow, self.window].contains(where: { $0.map(ObjectIdentifier.init) == window }) {
                        self.otherWindowTookKey = true
                    }
                }
            }
        }
        if handle.options.modalRegion != nil { modalLeftWindowUsable = true }
        // Tab and Shift-Tab cycle through this overlay's controls only.
        let keyViews = Self.keyViews(in: handle.content)
        for (index, view) in keyViews.enumerated() { view.nextKeyView = keyViews[(index + 1) % keyViews.count] }
        guard usesPanel else { return giveKeyboard(to: handle) }
        panel.acceptsKey = true
        panel.autorecalculatesKeyViewLoop = false
        if panel.isVisible { panel.makeKey() }
        let first = keyViews.first ?? handle.content
        panel.initialFirstResponder = first
        panel.makeFirstResponder(first)
    }

    /// `handle`, the newest modal, takes the keyboard where it draws: its window becomes key (the panel,
    /// or the main window for the top layer in it) and the first responder moves into it unless it is there.
    func giveKeyboard(to handle: OverlayHandle) {
        guard let overlayWindow else { return }
        if overlayWindow.isVisible, !overlayWindow.isKeyWindow { overlayWindow.makeKey() }
        if let responder = overlayWindow.firstResponder as? NSView, responder.isDescendant(of: handle.content) { return }
        overlayWindow.makeFirstResponder(Self.keyViews(in: handle.content).first ?? handle.content)
    }

    /// The keyboard is in the window's top layer while a modal shows there: an overlay's control is the
    /// window's first responder. The window's key routing treats the window as a panel over it then (no
    /// content shortcut runs), as it did while the overlay panel was key.
    public var keyboardIsInWindowTopLayer: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return holdsKeyboardInWindowTopLayer(responder)
    }

    /// `view` is a control of the window's top layer while a modal shows there (a dialog's field or button).
    public func holdsKeyboardInWindowTopLayer(_ view: NSView) -> Bool {
        isTopLayerInWindow && handles.contains { $0.options.isModal } && view.isDescendant(of: topLayer)
    }

    /// The window must not make `responder` its first responder: a view of the window's top layer while no
    /// modal shows (a popover, a toast's action, a menu). The overlay panel took the keyboard only while a
    /// modal showed (``beginModal(_:)``); a click on any other overlay leaves the keyboard in the pane.
    public func refusesFirstResponder(_ responder: NSResponder?) -> Bool {
        guard isTopLayerInWindow, let view = responder as? NSView, view.isDescendant(of: topLayer) else { return false }
        return !handles.contains { $0.options.isModal }
    }

    /// Tab or Shift-Tab reached the window (a field editor's `insertTab`) while the keyboard is in a modal
    /// in its top layer: focus moves within the modal. False: the window's own key view loop runs.
    public func cycleKeyViewInWindowTopLayer(forward: Bool) -> Bool {
        keyboardIsInWindowTopLayer && cycleKeyView(forward: forward)
    }

    func endModal() {
        guard !handles.contains(where: { $0.options.isModal }) else {
            if let top = handles.last(where: { $0.options.isModal }) {
                overlayWindow?.makeFirstResponder(Self.firstKeyView(in: top.content) ?? top.content)
            }
            return
        }
        madePanel?.acceptsKey = false
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        // Give the keyboard back only when no other window took it while the
        // overlay showed: after the person clicked into the window and moved
        // on (or another app was used), focus stays where it went.
        guard !isTearingDown, !focusMoved else {
            restoreWindow = nil
            restoreResponder = nil
            restoreSelection = nil
            return
        }
        let window = restoreWindow ?? self.window
        if let window, window.isVisible { window.makeKey() }
        if let responder = restoreResponder, let window {
            // A field editor stands in for its text field; give the field back.
            let target: NSResponder
            if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
                target = field
            } else {
                target = responder
            }
            // The field selects all its text when it takes the keyboard: put
            // the old selection back, only in that field, clamped to its text
            // (it may have got shorter while the modal showed).
            if window.makeFirstResponder(target), let selection = restoreSelection,
               let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, editor.delegate as AnyObject === target {
                editor.selectedRanges = Self.clamped(selection, length: (editor.string as NSString).length)
            }
        }
        restoreSelection = nil
        restoreWindow = nil
        restoreResponder = nil
    }

    /// The keyboard went elsewhere while the modal showed: another window took
    /// it, or, beside a tab dialog (the rest of the window takes clicks), the
    /// person clicked into the window: its first responder is no longer the
    /// one the modal took the keyboard from.
    var focusMoved: Bool {
        if otherWindowTookKey { return true }
        guard modalLeftWindowUsable, let keyWindow = restoreWindow ?? window, let saved = restoreResponder else { return false }
        var current = keyWindow.firstResponder
        if let editor = current as? NSTextView, editor.isFieldEditor { current = editor.delegate as? NSResponder }
        guard current !== saved else { return false }
        // In the window's top layer the overlay holds the window's keyboard, and the window itself holds it
        // once the overlay's view left: neither is a move.
        guard !usesPanel, keyWindow === window else { return true }
        return !(current == nil || current === keyWindow || (current as? NSView)?.isDescendant(of: topLayer) == true)
    }

    /// Escape reaches the panel only while it is key (a modal overlay). For
    /// a non-modal overlay that dismisses on Escape, a tap intercept lives
    /// while such an overlay shows and catches an Escape for any of the
    /// app's windows; it goes with the last such overlay. It also lives while
    /// a modal shows: when its window took the keyboard back (the app came
    /// back to the front), the modal still answers an Escape there. Its order,
    /// ``InputEventTap/InterceptOrder/modal``, puts it before every popup's.
    func updateEscapeIntercept() {
        let wanted = handles.contains { $0.options.dismissOnEscape || $0.options.isModal }
        if wanted, escapeIntercept == nil, let tap = requiredInputTap(inputTap, owner: "WindowOverlayHost.escape") {
            escapeIntercept = tap.subscribe(class: .key, phase: .intercept(order: .modal),
                                            while: { [weak self] in self?.handles.isEmpty == false }) { [weak self] event in
                self?.escapeEvent(event) ?? .pass
            }
        } else if !wanted {
            escapeIntercept = nil
        }
    }

    /// One key event of the Escape intercept: a plain Escape key down an overlay took is consumed.
    func escapeEvent(_ event: NSEvent) -> InputEventTap.InterceptResult {
        guard event.type == .keyDown, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              routeEscape(event, in: event.window) else { return .pass }
        return .consume
    }

    /// Tab inside the newest modal overlay: the next (or previous) control, wrapping.
    func cycleKeyView(forward: Bool) -> Bool {
        guard let top = handles.last(where: { $0.options.isModal }), let overlayWindow else { return false }
        let views = Self.keyViews(in: top.content)
        guard !views.isEmpty else { return true }
        var current = overlayWindow.firstResponder as? NSView
        if let editor = current as? NSTextView, editor.isFieldEditor { current = editor.delegate as? NSView }
        let index = current.flatMap { view in views.firstIndex { $0 === view } } ?? (forward ? views.count - 1 : 0)
        let next = views[(index + (forward ? 1 : views.count - 1)) % views.count]
        overlayWindow.makeFirstResponder(next)
        return true
    }

    /// Escape: the newest overlay that dismisses on Escape goes.
    func escape() {
        handles.last(where: { $0.options.dismissOnEscape })?.dismiss()
    }

    /// Controls that take the keyboard, in view order.
    /// `ranges` inside a text of `length` UTF-16 units (at least one, an insertion point at worst).
    static func clamped(_ ranges: [NSValue], length: Int) -> [NSValue] {
        let fitted = ranges.map { value -> NSValue in
            let range = value.rangeValue
            let start = min(max(range.location, 0), length)
            return NSValue(range: NSRange(location: start, length: min(range.length, length - start)))
        }
        return fitted.isEmpty ? [NSValue(range: NSRange(location: length, length: 0))] : fitted
    }

    static func keyViews(in view: NSView) -> [NSView] {
        var found: [NSView] = view.acceptsFirstResponder && view is NSControl ? [view] : []
        for child in view.subviews where !child.isHidden { found += keyViews(in: child) }
        return found
    }

    static func firstKeyView(in view: NSView) -> NSView? {
        if view.canBecomeKeyView { return view }
        for child in view.subviews {
            if let found = firstKeyView(in: child) { return found }
        }
        return nil
    }
}

extension WindowOverlayHost {
    /// An Escape for `target`, a window the panel is not: true when an overlay took it. The
    /// newest modal overlay takes it back while the keyboard did not move on (the person came
    /// back from another app and the window became key; in the window's top layer, every Escape
    /// while the modal shows); else the newest non-modal overlay that dismisses on Escape goes.
    func routeEscape(_ event: NSEvent, in target: NSWindow?) -> Bool {
        guard madePanel?.isKeyWindow != true, let target, isAppHost || target === window || target.parent === window else { return false }
        if let top = handles.last(where: { $0.options.isModal }), !focusMoved, let overlayWindow {
            giveKeyboard(to: top)
            overlayWindow.sendEvent(Self.retargeted(event, to: overlayWindow))
            return true
        }
        guard let handle = handles.last(where: { $0.options.dismissOnEscape && !$0.options.isModal }) else { return false }
        handle.dismiss()
        return true
    }

    /// `event` as a key press in `window`.
    static func retargeted(_ event: NSEvent, to window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                         timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil,
                         characters: event.characters ?? "", charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                         isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }
}
