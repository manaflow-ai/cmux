import AppKit
import SwiftUI

/// Hint mode (Show Hints, Cmd-J; cx-zjtn.5, ported from cmux-next): every
/// clickable control in the window gets a one or two letter label and
/// typing a whole label clicks that control, as the person's own click.
/// Typing a label's last letter with Shift right-clicks the control instead,
/// so context menus open from the keyboard. The shortcut router hands this
/// controller every key while labels show; Escape, a chord, any other key, a
/// click or a second Cmd-J ends it. Shown web pages are asked for their
/// elements first (``WindowHintPages``); keys typed meanwhile wait for the
/// labels. Behind `window-hints-release` until styled.
@MainActor
final class WindowHintController {
    static let shared = WindowHintController()

    struct Hint: Equatable {
        var label: String
        var target: WindowHintTargets.Target
    }

    private struct Session {
        var keys: WindowHintKeys
        weak var window: NSWindow?
        let overlay: NSWindow
        let hints: [Hint]
        let mouseMonitor: Any?
    }

    /// Asking the pages for their targets; the keys typed meanwhile.
    private struct Pending {
        let task: Task<Void, Never>
        weak var window: NSWindow?
        var keys: [NSEvent] = []
    }

    private var session: Session?
    private var pending: Pending?

    var isActive: Bool { session != nil || pending != nil }

    /// Labels `window`'s controls, or ends a session that shows (the action
    /// toggles). Returns false when nothing is clickable.
    @discardableResult
    func toggle(in window: NSWindow) -> Bool {
        guard !isActive else {
            cancel()
            return true
        }
        guard let content = window.contentView else { return false }
        let targets = WindowHintTargets.collect(in: content)
        let root = content.superview ?? content
        let pages = WindowHintPages.webViews(in: root)
        guard !pages.isEmpty else { return show(targets, in: window) }
        let clip = root.convert(root.bounds, to: nil)
        let task = Task { [weak self, weak window] in
            let found = await WindowHintPages.targets(of: pages, clip: clip)
            guard !Task.isCancelled, let self, let window, let waiting = self.pending else { return }
            self.pending = nil
            guard self.show(Array((targets + found).prefix(WindowHintTargets.limit)), in: window) else { return }
            for event in waiting.keys where self.session != nil { _ = self.interceptKeyDown(event, in: waiting.window) }
        }
        pending = Pending(task: task, window: window)
        return true
    }

    private func show(_ targets: [WindowHintTargets.Target], in window: NSWindow) -> Bool {
        let keys = WindowHintKeys(count: targets.count)
        guard !keys.labels.isEmpty else { return false }
        let hints = zip(keys.labels, targets).map { Hint(label: $0.0, target: $0.1) }
        let overlay = WindowHintOverlayWindow(over: window)
        window.addChildWindow(overlay, ordered: .above)
        // A click anywhere ends the session, as in cmux-next.
        let mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { WindowHintController.shared.cancel() }
            return event
        }
        session = Session(keys: keys, window: window, overlay: overlay, hints: hints, mouseMonitor: mouseMonitor)
        draw(prefix: "")
        return true
    }

    /// Every key-down while labels show (the shortcut router asks first).
    /// Returns whether the key was consumed; a key that ends the session
    /// without being a hint key goes on to the focused view.
    func interceptKeyDown(_ event: NSEvent, in window: NSWindow?) -> Bool {
        if pending != nil, session == nil {
            // Escape or another window ends the wait; anything else waits for the labels.
            guard event.keyCode != 53, window === pending?.window else {
                cancel()
                return event.keyCode == 53
            }
            pending?.keys.append(event)
            return true
        }
        guard var current = session, let home = current.window, window === home else {
            cancel()
            return false
        }
        if event.keyCode == 53 {
            cancel()
            return true
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        let outcome: WindowHintKeys.Outcome
        if flags.isEmpty, event.keyCode == 51 {
            outcome = current.keys.type(nil)
        } else if flags.isEmpty, let letter = event.charactersIgnoringModifiers?.lowercased(), letter.count == 1,
                  letter.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }) {
            outcome = current.keys.type(letter)
        } else {
            cancel()
            return false
        }
        session = current
        switch outcome {
        case .narrow(let prefix):
            draw(prefix: prefix)
        case .pick(let index):
            let hint = current.hints[index]
            cancel()
            let menu = event.modifierFlags.contains(.shift)
            if let page = hint.target.page {
                page.click(menu: menu)
            } else {
                Self.click(at: hint.target.center, in: home, menu: menu)
            }
        }
        return true
    }

    func cancel() {
        pending?.task.cancel()
        pending = nil
        guard let current = session else { return }
        session = nil
        if let monitor = current.mouseMonitor { NSEvent.removeMonitor(monitor) }
        current.window?.removeChildWindow(current.overlay)
        current.overlay.orderOut(nil)
    }

    /// The labels that start with `prefix`, in the overlay.
    private func draw(prefix: String) {
        guard let current = session, let view = current.overlay.contentView as? WindowHintOverlayView else { return }
        view.typed = prefix
        view.hints = current.hints.filter { $0.label.hasPrefix(prefix) }
    }

    /// A click at `point` (window coordinates), queued like the person's
    /// own: a control that tracks the mouse after the down finds the up.
    /// `menu`: a right mouse down alone, which opens the context menu and
    /// leaves it open for the keyboard (an up could pick the item under it).
    private static func click(at point: NSPoint, in window: NSWindow, menu: Bool) {
        let time = ProcessInfo.processInfo.systemUptime
        for type in menu ? [NSEvent.EventType.rightMouseDown] : [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// What is typed and every label, while labels show (`debug.window_hints`).
    var shown: (typed: String, hints: [Hint])? {
        session.map { ($0.keys.typed, $0.hints) }
    }
}

/// A click-through borderless window over the labelled window, so the
/// labels sit above every view (terminals and web views included) without
/// joining the window's own view or accessibility tree. Its content view's
/// coordinates are the parent window's.
private final class WindowHintOverlayWindow: NSWindow {
    convenience init(over window: NSWindow) {
        self.init(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = WindowHintOverlayView(frame: NSRect(origin: .zero, size: window.frame.size))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One small chip per label at its control's top-left corner, in the
/// Cmd-hold shortcut hints' palette (``ShortcutHintPalette``) for the
/// window's light or dark appearance. The typed part of a label is dimmed.
private final class WindowHintOverlayView: NSView {
    private static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 10, weight: .semibold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 10) } ?? base
    }()

    var hints: [WindowHintController.Hint] = [] {
        didSet { if hints != oldValue { needsDisplay = true } }
    }
    var typed = "" {
        didSet { if typed != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let appearance = window?.parent?.effectiveAppearance ?? effectiveAppearance
        let scheme: ColorScheme = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        let foreground = ShortcutHintPalette.foreground(for: scheme)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        for hint in hints {
            let label = hint.label.uppercased()
            let done = min(typed.count, label.count)
            let text = NSMutableAttributedString(string: label, attributes: [.font: Self.font, .foregroundColor: foreground])
            text.addAttribute(.foregroundColor, value: foreground.withAlphaComponent(0.4), range: NSRange(location: 0, length: done))
            let size = text.size()
            let chip = NSRect(x: hint.target.rect.minX, y: hint.target.rect.maxY - size.height - 3,
                              width: size.width + 8, height: size.height + 3).integral
            let shape = NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            ShortcutHintPalette.background(for: scheme).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            ShortcutHintPalette.border(for: scheme).setStroke()
            let rim = NSBezierPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
            rim.lineWidth = 1
            rim.stroke()
            text.draw(at: NSPoint(x: chip.minX + 4, y: chip.minY + 1.5))
        }
    }
}
