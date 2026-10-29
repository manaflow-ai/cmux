import CmuxNextCompat

/// The one terminal view of an app whose stream rides the input lane (``TerminalStreamPriority/focused``):
/// the last one that gained keyboard focus. Taking it demotes the view that held it, so at most one view's
/// output competes with the person's keys, as Chrome gives input priority only to the focused widget
/// (`RenderWidgetHostImpl::Focus`/`Blur`). Owned by the app's tab content cache and passed to each view's
/// ``TerminalAttachDriver``, which takes it on the main thread as focus moves
/// (``TerminalAttachDriver/takeStreamFocus()``), so takes apply in the person's order.
public nonisolated final class TerminalStreamFocus: Sendable {
    private nonisolated struct Holder: Sendable {
        let view: ObjectIdentifier
        let demote: @Sendable () -> Void
    }

    private let holder = Mutex<Holder?>(nil)

    public init() {}

    /// `view` gained focus; `demote` runs once when another view takes it. The previous holder's `demote`
    /// runs outside the lock.
    public func take(_ view: ObjectIdentifier, demote: @escaping @Sendable () -> Void) {
        let previous = holder.withLock { holder -> Holder? in
            guard holder?.view != view else { return nil }
            let previous = holder
            holder = Holder(view: view, demote: demote)
            return previous
        }
        previous?.demote()
    }

    /// `view` went away: nothing demotes it later.
    public func release(_ view: ObjectIdentifier) {
        holder.withLock { holder in
            if holder?.view == view { holder = nil }
        }
    }

    /// The view that holds focus (tests, diagnostics).
    public var holderView: ObjectIdentifier? { holder.withLock { $0?.view } }
}
