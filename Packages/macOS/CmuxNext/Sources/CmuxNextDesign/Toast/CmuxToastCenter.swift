public import AppKit
import CmuxNextWakeups

/// The one toast presenter (R96). Toasts show on their window's overlay
/// (`CmuxToastHosting`: native views on the R84 `WindowOverlayHost` in the app, `CmuxToastOverlayHost`), at most
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
        weak var window: NSWindow?
        let timer: DemandTimer
        /// Details is on: the whole message and its detail show.
        var showsDetails = false
    }

    /// Draws the toasts. The app sets its native host once at startup (its composition root), before
    /// any toast shows; until then toasts are kept and timed but drawn nowhere.
    public var host: any CmuxToastHosting
    private let clock: any Clock<Duration>
    private var entries: [Int: Entry] = [:]
    private var stacks: [ObjectIdentifier: CmuxToastStack] = [:]
    /// The window of each stack that shows toasts, so the host hears when its last toast goes.
    private var windows: [ObjectIdentifier: WeakWindow] = [:]
    private struct WeakWindow { weak var window: NSWindow? }
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

    public init(clock: any Clock<Duration> = ContinuousClock(), host: any CmuxToastHosting = CmuxToastNoHost()) {
        self.clock = clock
        self.host = host
    }

    // MARK: Showing

    @discardableResult
    public func show(_ toast: CmuxToast, in window: NSWindow) -> CmuxToastHandle {
        let serial = nextSerial
        nextSerial += 1
        let handle = CmuxToastHandle(serial: serial, toast: toast, center: self)
        // A one-window toast ends its copy in every other window, and in this one too when it stays
        // quiet below: a never-ending working toast is never left behind (``CmuxToast/oneWindow``).
        if toast.oneWindow {
            let quiet = isQuieted(toast)
            for (other, entry) in entries where entry.handle.toast.id == toast.id && (quiet || entry.window !== window) { end(other, .replaced) }
        }
        // The person closed this notice a moment ago: it does not come back yet.
        if isQuieted(toast) {
            handle.finish(.closed)
            return handle
        }
        let key = ObjectIdentifier(window)
        var stack = stacks[key] ?? CmuxToastStack()
        let newest = stack.serials.last
        // The same toast again while it shows (a repeated refusal): it stays in place and is not announced again.
        let repeats = newest.flatMap { entries[$0]?.handle.toast } == toast
        let replaced = stack.push(serial: serial, id: toast.id, undo: toast.action?.isUndo == true)
        stacks[key] = stack
        entries[serial] = Entry(handle: handle, window: window, timer: DemandTimer(owner: "toast", clock: clock))
        // The host draws the change as one transition: a same-id predecessor goes at once (its
        // successor takes its slot, and two different toasts never crossfade); one pushed over the
        // limit fades out while the rest restack.
        for old in replaced { end(old, .replaced, render: false) }
        // Its time starts before the host draws it: a toast that appears under a still pointer
        // holds at once (the host reports the pointer from its draw).
        startTimer(serial)
        render(key)
        if !repeats {
            NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
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
    /// button does (Details shows or hides the details in place); false when
    /// none shows or it has no action.
    @discardableResult
    public func runAction(id: String, in window: NSWindow) -> Bool {
        let serials = stacks[ObjectIdentifier(window)]?.serials ?? []
        guard let serial = serials.reversed().first(where: { entries[$0]?.handle.toast.id == id }),
              let entry = entries[serial], let action = entry.handle.toast.action else { return false }
        if action.revealsDetails { toggleDetails(serial) } else { entry.handle.runAction() }
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

    /// Ends the toast with `id` in every window (a run that ended with nothing to say, after its working
    /// toast showed in a window no longer in front). Unlike the close button it quiets nothing.
    public func close(id: String) {
        for (serial, entry) in entries where entry.handle.toast.id == id { end(serial, .closed) }
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

    // MARK: The host's reports

    /// The person clicked the toast's action button: Details shows or hides the details in place;
    /// any other action runs and ends the toast.
    public func personRanAction(serial: Int) {
        guard let entry = entries[serial], let action = entry.handle.toast.action else { return }
        if action.revealsDetails { toggleDetails(serial) } else { entry.handle.runAction() }
    }

    /// The person clicked the toast's close button.
    public func personClosed(serial: Int) {
        guard entries[serial] != nil else { return }
        closedByPerson(serial)
    }

    /// The pointer came onto or left the toast `serial`: on it, the toast holds.
    public func pointer(onToast serial: Int, _ hovered: Bool) {
        guard let handle = entries[serial]?.handle else { return }
        setHovered(hovered, handle)
    }

    /// `window` closed: its toasts end.
    public func windowClosed(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        for serial in stacks[key]?.serials ?? [] { end(serial, .closed, render: false) }
        stacks[key] = nil
        windows[key] = nil
    }

    // MARK: Details

    /// Details on or off: the toast shows its whole message and detail, or hides them again; the
    /// host restacks the window's toasts on its new height.
    private func toggleDetails(_ serial: Int) {
        guard var entry = entries[serial], let window = entry.window else { return }
        entry.showsDetails.toggle()
        entries[serial] = entry
        render(ObjectIdentifier(window))
    }

    /// Whether the toast `serial` shows its details now.
    public func showsDetails(serial: Int) -> Bool { entries[serial]?.showsDetails ?? false }

    // MARK: Ending

    func end(_ serial: Int, _ reason: CmuxToastDismissReason, render again: Bool = true) {
        guard let entry = entries.removeValue(forKey: serial) else { return }
        entry.timer.cancel()
        if let window = entry.window {
            let key = ObjectIdentifier(window)
            stacks[key]?.remove(serial)
            if again { render(key) }
        }
        entry.handle.finish(reason)
    }

    /// Gives the host the window's toasts as they are now, oldest first.
    private func render(_ key: ObjectIdentifier) {
        let serials = stacks[key]?.serials ?? []
        let newestUndo = stacks[key]?.newestUndo
        guard let window = serials.lazy.compactMap({ self.entries[$0]?.window }).first ?? windows[key]?.window else { return }
        windows[key] = serials.isEmpty ? nil : WeakWindow(window: window)
        // Cmd-Z runs the newest undo toast only: only its Undo shows the key.
        let shown = serials.compactMap { serial in
            entries[serial].map {
                CmuxToastShown(serial: serial, toast: $0.handle.toast, showsDetails: $0.showsDetails,
                               showsUndoKey: serial == newestUndo)
            }
        }
        host.show(shown, in: window, center: self)
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

    /// Runs the action (button, Cmd-Z, automation) and ends the toast. A
    /// Details action is the toast's own (it shows the details in place) and
    /// never ends it: ``CmuxToastCenter/runAction(id:in:)`` toggles it.
    public func runAction() {
        guard !isDismissed, toast.action != nil, toast.action?.revealsDetails != true else { return }
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
