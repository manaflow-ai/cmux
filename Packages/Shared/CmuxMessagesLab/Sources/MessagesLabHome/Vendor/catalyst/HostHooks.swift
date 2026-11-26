#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Host hooks (cmux Home, feat-cmux-next; cx-3cb host-hooks). A host such as cmux Home owns the data (its daemon);
// MessagesLab only offers these hooks, slots and callbacks. Every hook is off by default: with no hook set, nothing
// here runs a callback, adds a row, a layer or a menu item, and the window view draws exactly as without them.
//
// Ids: every hook speaks MessagesLab message ids (`Message.id`, the `ID` of `PartRef.messageId`), the ids the host
// gave its messages when it built them (cmux: `HomeMapping.id`). The host maps them to its own record ids.
//
// Ask 9 (the status line under the transcript) is engine state, not a hook: the host dispatches `.setNotice(text)`
// on the view's store (nil or "": no line); RowBuilder draws it as the last row.

/// What the user is on in one transcript (ask 10): the host reads it to hand the selection to another view.
struct HostSelection: Equatable {
    /// The focused message: the selected bubble (a click selects it, TranscriptSelection.selectBubble) or the
    /// target of the last message menu (`noteHostFocus`), whichever came last. nil: none (a click off every
    /// bubble clears it; a message deleted from the transcript clears it).
    var message: ID?
    /// The root message of the open thread view (`AppState.ui.openThread`), nil when no thread view is open.
    var threadRoot: ID?
}

/// The host's hooks on one window view. All nil by default (off).
struct HostHooks {
    /// Ask 10: called on main once per change of `MessagesWindowView.hostSelection` (the focused message or the
    /// open thread root), with the new value. Not called for the value at the time it is set. It runs synchronously
    /// at the end of a commit: a host that answers with an action dispatches it on a later run-loop turn.
    var selectionChanged: ((HostSelection) -> Void)?
    /// Ask 5: the message menu shows "Copy Link" (after Copy) and calls this with the message's id. nil: no item.
    /// cmux-only: Messages has no message links.
    var copyLink: ((ID) -> Void)?
    /// Ask 8: Edit in the message menu of my text bubbles. `available` decides per message (the host's record:
    /// mine, not retracted, its edit window); `commit` gets the new text when the inline editor saves (Return).
    /// The view does not change the message itself: the host's edit comes back as its new message.
    var edit: HostEdit?
    /// Ask 8: Undo Send in the message menu of my bubbles. `available` decides per message; `perform` retracts it.
    var undoSend: HostMessageAction?
    /// Whether the host decides Edit and Undo Send (either hook set): then MessagesLab's own rule (15 and 2 minutes
    /// after sending, appkit-native Host.menu) is off and each item exists only through its hook.
    var ownsEditing: Bool { edit != nil || undoSend != nil }
}

/// A host action on one message, with its per-message availability (HostHooks.undoSend).
struct HostMessageAction {
    var available: (ID) -> Bool
    var perform: (ID) -> Void
}

/// The host's Edit (HostHooks.edit).
struct HostEdit {
    var available: (ID) -> Bool
    var commit: (ID, String) -> Void
}

extension MessagesWindowView {
    // MARK: Ask 10: selection read

    /// The current selection (ask 10). Readable at any time; `hostHooks.selectionChanged` reports its changes.
    var hostSelection: HostSelection {
        HostSelection(message: hostFocus, threadRoot: store.state.ui.openThread?.messageId)
    }

    /// The host (or the shared selection code) moved the focus to message `id` (nil: no message): a bubble was
    /// selected or deselected, or the message menu opened on it. Draws nothing.
    func noteHostFocus(_ id: ID?) {
        guard hostFocus != id else { return }
        hostFocus = id
        reportHostSelection()
    }

    /// After every committed action (`commit`): a deleted focused message leaves the selection; a thread view that
    /// opened or closed changes it. Only compares ids when the hook is set.
    func hostSelectionAfter(_ action: Action) {
        if case let .delete(id) = action, id == hostFocus { hostFocus = nil }
        guard hostHooks.selectionChanged != nil else { return }
        reportHostSelection()
    }

    private func reportHostSelection() {
        guard let report = hostHooks.selectionChanged else { return }
        let now = hostSelection
        guard now != hostSelectionReported else { return }
        hostSelectionReported = now
        report(now)
    }
}

extension MessagesWindowView {
    // MARK: Ask 5: reveal one message (a permalink opened)

    /// The highlight's timing (cmux-only: Messages opens no message links, so there is no reference for a flash).
    /// Its look is Messages' selected bubble (TranscriptSelection.selectBubble; click-incoming and click-outgoing
    /// references: incoming white at 20 %, outgoing darkened to (45,91,192)): in over 0.22 s, held, out over 0.5 s.
    static let revealIn = 0.22, revealHold = 1.0, revealOut = 0.5

    /// Shows message `id` and, with `highlight`, flashes its bubbles. In the open thread view: its copy there (no
    /// scroll). Else the main transcript scrolls so its first row sits under the header (as a jump lands,
    /// `show(seqIndex:)`), within the scroll range. False, and nothing changes, when no row of the message is shown:
    /// with a thread view open, the message is not in it (the host closes the view, `.closeThread`, and calls again);
    /// else it is not in the loaded window (the host loads a window around it, `.replaceWindow`, and calls again).
    @discardableResult
    func revealHostMessage(_ id: ID, highlight: Bool = true) -> Bool {
        if threadOpen {
            var found = false
            for (v, spec) in zip(threadViews, threadSpecs) where RowBuilder.key(spec.key, belongsTo: id) {
                guard case let .part(row) = spec.kind else { continue }
                found = true
                if highlight { flashReveal(in: v.layer, body: RowDraw.bodyRect(spec), row: row) }
            }
            return found
        }
        guard let i = model.rows.firstIndex(where: { !$0.ghost && $0.spec.key.hasPrefix("part:") && RowBuilder.key($0.spec.key, belongsTo: id) })
        else { return false }
        let y = layout.contentTop(i) - (Fixture.headerHeight + 8 - MessagesWindowView.cvTop) - 8
        setOffset(min(max(minOffset, y), pinnedOffset))
        collection.setNeedsLayout(); collection.layoutIfNeeded()
        userScrolled()
        guard highlight else { return true }
        // The flash lives in the list's content (it scrolls with the rows), over the cells.
        for case let cell as RowCell in collection.visibleCells {
            guard let spec = cell.spec, case let .part(row) = spec.kind, RowBuilder.key(spec.key, belongsTo: id) else { continue }
            let body = cell.convert(RowDraw.bodyRect(spec), to: collection).offsetBy(dx: cell.rowSnap.x, dy: cell.rowSnap.y)
            flashReveal(in: collection.layer, body: body, row: row)
        }
        return true
    }

    /// One bubble's flash in `container` (`body`: the bubble's frame there).
    private func flashReveal(in container: CALayer, body: CGRect, row: PartRow) {
        let outline = RowDraw.balloon(body, row: row, scale: renderScale)
        let l = CAShapeLayer()
        l.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
        l.path = BubblePath.make(body: outline, outgoing: row.outgoing, tail: row.tail, cornersOf: body.size,
                                 circularEnds: RowDraw.circularEnds(row)).cgPath
        // TranscriptSelection's fills: a normal-blended fill that gives Messages' selected-bubble colours.
        l.fillColor = row.outgoing ? UIColor(red: 0, green: 0, blue: 102 / 255, alpha: 0.38).cgColor : UIColor(white: 1, alpha: 0.2).cgColor
        // Above every row: a cell's layer takes its row index as its zPosition (ChatLayout zIndex, RowRecycler).
        l.zPosition = 1_000_000_000
        // The render server skips a layer whose model opacity is exactly 0 (README); the layer leaves at the end.
        l.opacity = 0.01
        let total = Self.revealIn + Self.revealHold + Self.revealOut
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 1, 1, 0]
        a.keyTimes = [0, Self.revealIn / total, (Self.revealIn + Self.revealHold) / total, 1].map { NSNumber(value: $0) }
        a.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeOut)]
        a.duration = total
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        container.addSublayer(l)
        l.add(a, forKey: "reveal")
        CATransaction.commit()
    }
}
