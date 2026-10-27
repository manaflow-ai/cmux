public import AppKit
import CmuxNextWakeups

/// The one toast presenter (R96). Toasts show on their window's overlay
/// (`CmuxToastHosting`, the R84 `WindowOverlayHost` in the app), at most
/// three per window with the newest at the bottom (`CmuxToastStack`). Each
/// ends after its duration on the injected clock; the pointer on a toast
/// holds it. Cmd-Z runs the newest undo toast only when the focused
/// responder has nothing of its own to undo: the key dispatcher (owned by
/// the keybindings lead) asks `takesUndoKey(in:)` and calls `runUndo(in:)`.
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
    /// Notices the person closed, quiet until their timer ends.
    private var quieted: [QuietKey: DemandTimer] = [:]
    /// How long a notice the person closed stays quiet: the same message
    /// (same id and detail, no action) asked for again in that time does not show.
    /// A toast with an action (Undo, Reopen, Retry) is never quieted.
    public var closedCooldown: Duration = .seconds(120)

    /// A notice by what it says: its id, message and detail.
    private struct QuietKey: Hashable {
        let id: String
        let message: String
        let detail: String?
        init(_ toast: CmuxToast) {
            id = toast.id
            message = toast.message
            detail = toast.detail
        }
    }

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
        // The person closed this notice a moment ago: it does not come back yet.
        if isQuieted(toast) {
            handle.finish(.closed)
            return handle
        }
        let view = CmuxToastView(toast: toast)
        view.onAction = { [weak handle] in handle?.runAction() }
        view.onClose = { [weak self] in self?.closedByPerson(serial) }
        view.onHover = { [weak self, weak handle] hovered in
            guard let handle else { return }
            self?.setHovered(hovered, handle)
        }
        let key = ObjectIdentifier(window)
        var stack = stacks[key] ?? CmuxToastStack()
        let newest = stack.serials.last
        // The same toast again while it shows (a repeated refusal): it stays in place and is not announced again.
        let repeats = newest.flatMap { entries[$0]?.handle.toast } == toast
        let replaced = stack.push(serial: serial, id: toast.id, undo: toast.action?.isUndo == true)
        stacks[key] = stack
        entries[serial] = Entry(handle: handle, view: view, window: window, timer: DemandTimer(owner: "toast", clock: clock))
        // A same-id toast goes at once (its successor takes the slot, and two
        // different toasts never crossfade); one pushed over the limit fades.
        // A successor of the newest toast shows in its slot at once, so a
        // repeated toast never blinks out and fades back in.
        let inPlace = newest.map { replaced.contains($0) && entries[$0]?.handle.toast.id == toast.id } ?? false
        for old in replaced {
            let fades = entries[old]?.handle.toast.id != toast.id
            // One pushed out fades a slot above the stack, clear of the toast moving into its slot.
            if fades, let view = entries[old]?.view { host.move(view, to: stack.serials.count) }
            end(old, .replaced, relayout: false, animated: fades)
        }
        host.show(view, in: window, slot: 0, appearing: !inPlace) { [weak self] in self?.windowClosed(key) }
        relayout(key)
        startTimer(serial)
        // A toast that appears under a still pointer holds at once.
        if view.isHovered { setHovered(true, handle) }
        if !repeats {
            NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
                .announcement: toast.message, .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
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
        guard let serial = stacks[ObjectIdentifier(window)]?.newestUndo else { return false }
        let responder = window.firstResponder
        // The toast's own step on top of the responder's undo stack does not take the key from it.
        return !Self.responderCanUndo(responder) || entries[serial]?.handle.ownsUndoTop?(responder?.undoManager) == true
    }

    /// Runs the newest undo toast's action in `window`; false when none shows.
    @discardableResult
    public func runUndo(in window: NSWindow) -> Bool {
        guard let serial = stacks[ObjectIdentifier(window)]?.newestUndo, let handle = entries[serial]?.handle else { return false }
        handle.runAction()
        return true
    }

    /// Runs the action of the newest toast with `id` in `window`, as its
    /// button does; false when none shows or it has no action.
    @discardableResult
    public func runAction(id: String, in window: NSWindow) -> Bool {
        let serials = stacks[ObjectIdentifier(window)]?.serials ?? []
        guard let handle = serials.reversed().lazy.compactMap({ self.entries[$0]?.handle }).first(where: { $0.toast.id == id }),
              handle.toast.action != nil else { return false }
        handle.runAction()
        return true
    }

    /// Closes the newest toast with `id` in `window`, as its close button
    /// does; false when none shows.
    @discardableResult
    public func close(id: String, in window: NSWindow) -> Bool {
        let serials = stacks[ObjectIdentifier(window)]?.serials ?? []
        guard let serial = serials.reversed().first(where: { entries[$0]?.handle.toast.id == id }) else { return false }
        closedByPerson(serial)
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

    // MARK: Quiet after close

    /// Whether `toast` is a notice the person closed less than
    /// ``closedCooldown`` ago (same id, message and detail, no action).
    public func isQuieted(_ toast: CmuxToast) -> Bool {
        toast.action == nil && quieted[QuietKey(toast)] != nil
    }

    /// The close button: the toast ends, and a notice without an action
    /// stays quiet for ``closedCooldown``.
    func closedByPerson(_ serial: Int) {
        if let toast = entries[serial]?.handle.toast, toast.action == nil, closedCooldown > .zero {
            let quiet = QuietKey(toast)
            quieted[quiet]?.cancel()
            let timer = DemandTimer(owner: "toast.quiet", clock: clock)
            quieted[quiet] = timer
            timer.schedule(after: closedCooldown) { @MainActor [weak self] in self?.quieted[quiet] = nil }
        }
        end(serial, .closed)
    }

    // MARK: Ending

    func end(_ serial: Int, _ reason: CmuxToastDismissReason, relayout again: Bool = true, animated: Bool = true) {
        guard let entry = entries.removeValue(forKey: serial) else { return }
        entry.timer.cancel()
        host.hide(entry.view, animated: animated)
        if let window = entry.window {
            let key = ObjectIdentifier(window)
            stacks[key]?.remove(serial)
            if again { relayout(key) }
        }
        entry.handle.finish(reason)
    }

    private func windowClosed(_ key: ObjectIdentifier) {
        for serial in stacks[key]?.serials ?? [] { end(serial, .closed, relayout: false) }
        stacks[key] = nil
    }

    private func relayout(_ key: ObjectIdentifier) {
        let serials = stacks[key]?.serials ?? []
        let newestUndo = stacks[key]?.newestUndo
        for (index, serial) in serials.reversed().enumerated() {
            guard let view = entries[serial]?.view else { continue }
            host.move(view, to: index)
            // Cmd-Z runs the newest undo toast only: only its Undo shows the key.
            view.showsUndoKey = serial == newestUndo
        }
        // The toasts moved under a possibly still pointer: a hovered toast
        // that moved away loses its hold and its timer starts again (cx-3wu5).
        // Window-wide: the toasts' buttons moved too.
        PointerHover.refresh(in: serials.lazy.compactMap { self.entries[$0]?.view.window }.first)
    }

    private func startTimer(_ serial: Int) {
        guard let entry = entries[serial], entry.handle.toast.duration != CmuxToast.untilClosed else { return }
        entry.timer.schedule(after: entry.handle.toast.duration) { @MainActor [weak self] in
            self?.end(serial, .timeout)
        }
    }
}

/// One shown toast. `onAction` runs once when its action runs; `onDismiss`
/// once when it ends, with the reason.
@MainActor
public final class CmuxToastHandle {
    public let toast: CmuxToast
    public var onAction: (() -> Void)?
    public var onDismiss: ((CmuxToastDismissReason) -> Void)?
    /// Whether this toast's step is the top of the given undo stack (an undo
    /// toast that also put its step on the window's undo stack): Cmd-Z then
    /// stays the toast's while it shows.
    public var ownsUndoTop: ((UndoManager?) -> Bool)?
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
