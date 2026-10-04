public import AppKit
import CmuxNextWakeups

/// The one toast presenter (R96). Toasts show on their window's overlay
/// (`CmuxToastHosting`, the R84 `WindowOverlayHost` in the app), at most
/// three per window with the newest at the bottom (`CmuxToastStack`). Each
/// ends after its duration on the injected clock; the pointer on a toast
/// holds it. Cmd-Z runs the newest undo toast only when the focused
/// responder has nothing of its own to undo (`takesUndoKey`).
@MainActor
public final class CmuxToastCenter {
    public static let shared = CmuxToastCenter()

    private struct Entry {
        let handle: CmuxToastHandle
        let view: CmuxToastView
        weak var window: NSWindow?
        let timer: DemandTimer
    }

    public let host: any CmuxToastHosting
    private let clock: any Clock<Duration>
    private var entries: [Int: Entry] = [:]
    private var stacks: [ObjectIdentifier: CmuxToastStack] = [:]
    private var nextSerial = 1
    private var keyMonitor: Any?

    public init(clock: any Clock<Duration> = ContinuousClock(), host: any CmuxToastHosting = CmuxToastOverlayHost()) {
        self.clock = clock
        self.host = host
    }

    // MARK: Showing

    @discardableResult
    public func show(_ toast: CmuxToast, in window: NSWindow) -> CmuxToastHandle {
        let serial = nextSerial
        nextSerial += 1
        let handle = CmuxToastHandle(serial: serial, toast: toast, center: self)
        let view = CmuxToastView(toast: toast)
        view.onAction = { [weak handle] in handle?.runAction() }
        view.onClose = { [weak self] in self?.end(serial, .closed) }
        view.onHover = { [weak self, weak handle] hovered in
            guard let handle else { return }
            self?.setHovered(hovered, handle)
        }
        let key = ObjectIdentifier(window)
        var stack = stacks[key] ?? CmuxToastStack()
        let replaced = stack.push(serial: serial, id: toast.id, undo: toast.action?.isUndo == true)
        stacks[key] = stack
        entries[serial] = Entry(handle: handle, view: view, window: window, timer: DemandTimer(owner: "toast", clock: clock))
        for old in replaced { end(old, .replaced, relayout: false) }
        host.show(view, in: window, slot: 0) { [weak self] in self?.windowClosed(key) }
        relayout(key)
        startTimer(serial)
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
            .announcement: toast.message, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        syncKeyMonitor()
        return handle
    }

    /// The toasts `window` shows, oldest first.
    public func toasts(in window: NSWindow) -> [CmuxToast] {
        (stacks[ObjectIdentifier(window)]?.serials ?? []).compactMap { entries[$0]?.handle.toast }
    }

    // MARK: Undo key

    /// Whether Cmd-Z in `window` goes to a toast: an undo toast shows and the
    /// focused responder has nothing to undo (a text field, terminal, editor
    /// or page with its own undo keeps the key).
    public func takesUndoKey(in window: NSWindow) -> Bool {
        stacks[ObjectIdentifier(window)]?.newestUndo != nil && !Self.responderCanUndo(window.firstResponder)
    }

    /// Runs the newest undo toast's action in `window`; false when none shows.
    @discardableResult
    public func runUndo(in window: NSWindow) -> Bool {
        guard let serial = stacks[ObjectIdentifier(window)]?.newestUndo, let handle = entries[serial]?.handle else { return false }
        handle.runAction()
        return true
    }

    /// The responder chain from `responder` has an undo manager that can undo.
    public static func responderCanUndo(_ responder: NSResponder?) -> Bool {
        responder?.undoManager?.canUndo == true
    }

    // MARK: Hover

    /// The pointer on a toast holds it; leaving starts its full time again.
    public func setHovered(_ hovered: Bool, _ handle: CmuxToastHandle) {
        guard entries[handle.serial] != nil else { return }
        if hovered {
            entries[handle.serial]?.timer.cancel()
        } else if entries[handle.serial]?.timer.isScheduled == false {
            startTimer(handle.serial)
        }
    }

    // MARK: Ending

    func end(_ serial: Int, _ reason: CmuxToastDismissReason, relayout again: Bool = true) {
        guard let entry = entries.removeValue(forKey: serial) else { return }
        entry.timer.cancel()
        host.hide(entry.view)
        if let window = entry.window {
            let key = ObjectIdentifier(window)
            stacks[key]?.remove(serial)
            if again { relayout(key) }
        }
        entry.handle.finish(reason)
        syncKeyMonitor()
    }

    private func windowClosed(_ key: ObjectIdentifier) {
        for serial in stacks[key]?.serials ?? [] { end(serial, .closed, relayout: false) }
        stacks[key] = nil
    }

    private func relayout(_ key: ObjectIdentifier) {
        let serials = stacks[key]?.serials ?? []
        for (index, serial) in serials.reversed().enumerated() {
            if let view = entries[serial]?.view { host.move(view, to: index) }
        }
    }

    private func startTimer(_ serial: Int) {
        guard let entry = entries[serial] else { return }
        entry.timer.schedule(after: entry.handle.toast.duration) { @MainActor [weak self] in
            self?.end(serial, .timeout)
        }
    }

    /// Cmd-Z reaches the toasts through one local key monitor, installed only
    /// while an undo toast shows.
    private func syncKeyMonitor() {
        let wanted = stacks.values.contains { $0.newestUndo != nil }
        if wanted, keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = event.window, Self.isUndoKey(event), self.takesUndoKey(in: window) else { return event }
                self.runUndo(in: window)
                return nil
            }
        } else if !wanted, let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    static func isUndoKey(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && event.charactersIgnoringModifiers == "z"
    }
}

/// One shown toast. `onAction` runs once when its action runs; `onDismiss`
/// once when it ends, with the reason.
@MainActor
public final class CmuxToastHandle {
    public let toast: CmuxToast
    public var onAction: (() -> Void)?
    public var onDismiss: ((CmuxToastDismissReason) -> Void)?
    public private(set) var isDismissed = false
    let serial: Int
    private weak var center: CmuxToastCenter?

    init(serial: Int, toast: CmuxToast, center: CmuxToastCenter) {
        self.serial = serial
        self.toast = toast
        self.center = center
    }

    /// Runs the action (button, Cmd-Z, automation) and ends the toast.
    public func runAction() {
        guard !isDismissed, toast.action != nil else { return }
        let action = onAction
        onAction = nil
        action?()
        center?.end(serial, .action)
    }

    public func dismiss() {
        center?.end(serial, .closed)
    }

    func finish(_ reason: CmuxToastDismissReason) {
        guard !isDismissed else { return }
        isDismissed = true
        onAction = nil
        let callback = onDismiss
        onDismiss = nil
        callback?(reason)
    }
}
