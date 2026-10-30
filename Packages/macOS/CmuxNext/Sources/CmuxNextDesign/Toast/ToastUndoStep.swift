public import AppKit

// The pin and sidebar undo step (moved from CmuxNextApp's PinCommands, SW14): the toast's Undo and the window's
// Edit > Undo share it, so either runs the inverse once.

/// One undo step shared by the toast and the window's undo stack: it runs
/// its inverse once, whichever path comes first.
@MainActor
public final class ToastUndoStep: NSObject {
    /// Steps on an undo stack (an undo manager does not retain its target); a step leaves when it runs or is abandoned.
    private static var held: Set<ToastUndoStep> = []
    /// The step registered last (a newer one is the top of its stack, not this).
    static weak var newest: ToastUndoStep?
    /// The step an undo or redo of the stack put for the inverse running now (set only while it runs).
    public static var filling: ToastUndoStep?
    private var inverse: (() -> Void)?
    private var title: String
    weak var handle: CmuxToastHandle?
    weak var undoManager: UndoManager?

    init(title: String, _ inverse: (@MainActor () -> Void)?) {
        self.title = title
        self.inverse = inverse
    }

    /// Shares one step between the toast `handle` and `undoManager` (the window's undo stack); `run` is the inverse.
    /// A nil `handle` puts the step on the undo stack only (Edit > Undo, Cmd-Z), with no toast.
    /// An inverse run from the undo stack fills the step the undo put at once on the other side (`filling`: its own
    /// step, passed through the daemon reply; or the step whose inverse is running now), so it is the redo (or, from
    /// a redo, the next undo), not a new undo that clears the redo. Any other change registers a new step.
    @discardableResult
    public static func attach(title: String, filling: ToastUndoStep?, undoManager: UndoManager?, handle: CmuxToastHandle?,
                              _ run: @escaping @MainActor () -> Void) -> ToastUndoStep {
        let step: ToastUndoStep
        if let target = filling ?? Self.filling, target.isEmpty, target.undoManager === undoManager {
            step = target
            step.fill(title: title, run)
        } else {
            step = ToastUndoStep(title: title, run)
            step.undoManager = undoManager
            step.register()
        }
        step.handle = handle
        Self.newest = step
        handle?.onAction = { step.run(fromToast: true) }
        handle?.ownsUndoTop = { [weak step] manager in step?.isTop(of: manager) == true }
        return step
    }

    /// The step registered last: a change that just registered one (the sidebar document's, through the App) is it.
    public static var latest: ToastUndoStep? { newest }

    /// Gives this step a toast: the toast's Undo runs this step's inverse, never another change's on the stack's top.
    public func share(with handle: CmuxToastHandle) {
        self.handle = handle
        handle.onAction = { [self] in run(fromToast: true) }
        handle.ownsUndoTop = { [weak self] manager in self?.isTop(of: manager) == true }
    }

    /// A step for a change sent and not answered yet (cx-kpicb): it is on the stack and its toast shows from the send, so
    /// the next Cmd-Z undoes this change, not the one before it. `fill` gives it the inverse when the reply comes; an
    /// undo that comes first runs the inverse then. `abandon` (refused, a no-op) takes it off the stack and the toast.
    public static func pending(title: String, undoManager: UndoManager?, handle: CmuxToastHandle?) -> ToastUndoStep {
        let step = ToastUndoStep(title: title, nil)
        step.undoManager = undoManager
        step.awaitsReply = true
        step.register()
        step.handle = handle
        Self.newest = step
        handle?.onAction = { step.run(fromToast: true) }
        handle?.ownsUndoTop = { [weak step] manager in step?.isTop(of: manager) == true }
        return step
    }

    /// Made by `pending`: its toast already shows, so the reply only fills it.
    public private(set) var awaitsReply = false
    /// An undo that ran before the inverse came: from the toast, or from the stack with the step it put on the redo side.
    private enum Requested { case toast, stack(ToastUndoStep) }
    private var requested: Requested?

    /// Undos asked for while a pending step waits for its inverse, in the order asked: they run in that order (the
    /// daemon gets B's inverse before A's when B was undone first), each once its inverse is there.
    private static var queue: [ToastUndoStep] = []

    /// The pending step's inverse came: it is the undo now, or it runs (in the order asked) when an undo asked for it.
    public func fillPending(title: String, _ inverse: @escaping @MainActor () -> Void) {
        guard isEmpty else { return }
        fill(title: title, inverse)
        Self.drain()
    }

    /// Runs the asked-for undos at the head of the queue whose inverses are there.
    private static func drain() {
        while let first = queue.first, first.inverse != nil {
            queue.removeFirst()
            first.runRequested()
        }
    }

    private func runRequested() {
        guard let inverse, let asked = requested else { return }
        requested = nil
        self.inverse = nil
        awaitsReply = false
        Self.held.remove(self)
        switch asked {
        case .toast: inverse()
        case let .stack(redo):
            Self.filling = redo
            defer { Self.filling = nil }
            inverse()
        }
    }

    /// Puts the step on its stack (on the redo side while the stack undoes).
    func register() {
        guard let undoManager else { return }
        Self.held.insert(self) // it outlives the toast
        Self.registered &+= 1
        // One user action is one undo group: its own explicit top-level group, also when another step's reply registered
        // in the same run-loop pass. An undo's or redo's step goes into the group the undo manager opened for it.
        let ownGroup = !undoManager.isUndoing && !undoManager.isRedoing
        // With groupsByEvent on, beginUndoGrouping at level 0 first opens the run loop's automatic group and nests the
        // explicit one in it (live21: two quick section edits whose replies came in one pass shared that automatic group,
        // and one Edit > Undo undid both). By-event grouping is off while the step opens and closes its group, so the group
        // is top-level and no automatic group is left open for the next step. At a level above 0 another registration in
        // this pass already opened the automatic group: the step can only nest in it (closing a group it did not open
        // would unbalance the manager).
        let byEvent = undoManager.groupsByEvent
        let topLevel = ownGroup && undoManager.groupingLevel == 0
        if topLevel { undoManager.groupsByEvent = false }
        defer { if topLevel { undoManager.groupsByEvent = byEvent } }
        if ownGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self, selector: #selector(performUndo(_:)), object: nil)
        undoManager.setActionName(title)
        if ownGroup { undoManager.endUndoGrouping() }
    }

    /// Steps put on an undo stack so far (`debug.toast` `undo_steps`): automation waits for a change's step before Edit > Undo.
    public static private(set) var registered = 0

    /// The undo stack's action (on the main thread, as every undo).
    @objc private func performUndo(_ sender: Any?) {
        run(fromToast: false)
    }

    /// A step put for an inverse that has not come yet.
    var isEmpty: Bool { inverse == nil && !abandoned }
    private var abandoned = false

    func fill(title: String, _ inverse: @escaping @MainActor () -> Void) {
        self.title = title
        self.inverse = inverse
    }

    /// Its inverse never comes (refused, or a no-op): the stack loses the empty step (a pending step also its toast, and
    /// the redo step an early undo put for it).
    public func abandon() {
        guard isEmpty else { return }
        abandoned = true
        undoManager?.removeAllActions(withTarget: self)
        Self.held.remove(self)
        if case let .stack(redo)? = requested { redo.abandon() }
        requested = nil
        if let index = Self.queue.firstIndex(of: self) { Self.queue.remove(at: index); Self.drain() }
        if awaitsReply, let handle, !handle.isDismissed {
            handle.onAction = nil
            handle.dismiss()
        }
    }

    /// Still to run, registered last, and the top of `manager` (its action name).
    func isTop(of manager: UndoManager?) -> Bool {
        guard let manager, inverse != nil || (awaitsReply && isEmpty && requested == nil), Self.newest === self, manager === undoManager
        else { return false }
        return manager.undoActionName == title
    }

    func run(fromToast: Bool) {
        guard let inverse else { return runBeforeReply(fromToast: fromToast) }
        // An earlier-asked undo still waits for its inverse: this one runs after it.
        if !Self.queue.isEmpty { return runBeforeReply(fromToast: fromToast) }
        defer { if self.inverse == nil { Self.held.remove(self) } }
        if fromToast {
            self.inverse = nil
            undoManager?.removeAllActions(withTarget: self) // not the top: the stack loses the step
            inverse()
            return
        }
        self.inverse = nil
        if let handle, !handle.isDismissed {
            handle.onAction = nil
            handle.dismiss() // the stack ran it: the toast goes
        }
        if let undoManager, undoManager.isUndoing || undoManager.isRedoing {
            // The inverse's step goes on the other side now, while the stack undoes or redoes; the inverse fills it.
            let next = ToastUndoStep(title: title, nil)
            next.undoManager = undoManager
            next.register()
            Self.filling = next
            defer { Self.filling = nil }
            inverse()
            return
        }
        inverse()
    }

    /// An undo of a pending step before its inverse came: it runs when `fillPending` brings the inverse. From the stack,
    /// the step for the redo goes on the other side now, as for any undo.
    private func runBeforeReply(fromToast: Bool) {
        guard requested == nil, inverse != nil || (awaitsReply && !abandoned) else { return }
        if let handle, !handle.isDismissed {
            handle.onAction = nil
            handle.dismiss()
        }
        if fromToast {
            undoManager?.removeAllActions(withTarget: self)
            requested = .toast
            Self.queue.append(self)
            return
        }
        guard let undoManager, undoManager.isUndoing || undoManager.isRedoing else { return }
        let next = ToastUndoStep(title: title, nil)
        next.undoManager = undoManager
        next.register()
        requested = .stack(next)
        Self.queue.append(self)
    }
}
