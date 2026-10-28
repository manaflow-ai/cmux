import AppKit
import CmuxNextDesign

/// The rows one `SidebarListView.apply` animates, all on one spring
/// (cx-bqm6): like a browser's vertical tabs, existing rows move, new rows
/// open their slot and removed rows close theirs, so no row overlaps another
/// or waits for it. Group lines and the chat history blocks move on the same
/// render-server springs from the same begin time (`animate`), so a line ends
/// at its group's last row in every frame (cx-ai79).
@MainActor
struct RowMotion {
    var targets: [(SidebarRowView, NSRect)]
    var appearing: [(SidebarRowView, NSRect)]
    var leaving: [(SidebarRowView, NSRect)]
    var lines: SidebarGroupLineViews.LineMotion
    /// The chat history blocks with their frames (`SidebarChatHistoryViews.place`): they move with the rows.
    var companions: [(NSView, NSRect)] = []

    func run(in list: SidebarListView, from old: SidebarLayout, to layout: SidebarLayout, animated: Bool) {
        let moves = {
            for (view, target) in targets {
                view.animator().frame = target
                view.animator().alphaValue = 1
            }
        }
        // A change without motion also ends a move still running from an earlier one: its springs come off,
        // so every row shows its slot now (`SidebarDragSpring.stop`).
        let views = targets.map(\.0) + appearing.map(\.0) + leaving.map(\.0)
        guard animated else {
            Motion.withoutAnimation {
                moves()
                lines.changes()
            }
            SidebarDragSpring.stop(views)
            Self.untuck(views)
            leaving.forEach { Self.closed($0.0, in: list) }
            lines.leaving.forEach { $0.removeFromSuperview() }
            return
        }
        guard Motion.sidebar.animatesMovement else {
            // Reduce Motion: rows take their places in one step, with no crossfade standing in
            // for the motion (DESIGN P6): no movement, and nothing a person must wait out.
            Motion.withoutAnimation {
                moves()
                lines.changes()
                for (view, target) in appearing {
                    view.frame = target
                    view.alphaValue = 1
                    view.clipsToBounds = false
                }
            }
            SidebarDragSpring.stop(views)
            Self.untuck(views)
            // Movement off: the lines and history blocks land too, their earlier springs off (`move`'s snap).
            SidebarDragSpring.move(lines.springs + companions, in: list)
            leaving.forEach { Self.closed($0.0, in: list) }
            lines.leaving.forEach { $0.removeFromSuperview() }
            return
        }
        passOver(in: list, from: old, to: layout)
        for (view, end) in leaving { view.closingEnd = end }
        let opens = appearing.map(\.0.opens)
        list.rowMoves &+= 1
        let move = list.rowMoves
        let ended = RowMotionEnd { [weak list, appearing, opens, leaving, targets, leavingLines = lines.leaving] in
            leavingLines.forEach { $0.removeFromSuperview() }
            // Every line of this move, those that only moved too: an earlier move's tuck they kept ends here at the latest.
            Self.untuck(targets.map(\.0) + appearing.map(\.0) + leaving.map(\.0), move: move)
            guard let list else { return }
            // A row reopened since keeps clipping until its own open ends.
            for ((view, _), open) in zip(appearing, opens) where view.opens == open { view.clipsToBounds = false }
            for (view, _) in leaving where !list.rowViews.values.contains(where: { $0 === view }) { Self.closed(view, in: list) }
            if list.rowMoves == move { Self.land(list) }
            list.pruneOffscreen()
        }
        let moving = Set((targets + appearing + leaving).filter { $0.0.frame != $0.1 }.map { ObjectIdentifier($0.0) })
        let tucked = Self.tuck(appearing: appearing, leaving: leaving, move: move) {
            Self.cover(of: $0, rows: list.rowViews, moving: moving)
        }
        // A line an earlier move tucked that now appears or leaves untucked (its row moves with a group) goes back to
        // the rows' drawing order, and the shared fade takes it over (Codex review). A line that only moves keeps its
        // tuck: no shared fade would take its place, so it would show at once; its own move's end untucks it.
        Self.untuck((appearing + leaving).map(\.0).filter { !tucked.contains(ObjectIdentifier($0)) })
        Self.animate(frames: targets + appearing + leaving, companions: lines.springs + companions,
                     fades: Self.fades(targets: targets, appearing: appearing, leaving: leaving).filter { !tucked.contains(ObjectIdentifier($0.0)) },
                     lines: lines.changes, in: list, ended: ended)
    }

    /// The views whose opacity this move changes and to what: an opening row and a target still fading in to 1,
    /// a closing row to 0. A handful whatever the list's length (a target already opaque is left out).
    private static func fades(targets: [(SidebarRowView, NSRect)], appearing: [(SidebarRowView, NSRect)],
                              leaving: [(SidebarRowView, NSRect)]) -> [(NSView, CGFloat)] {
        var fades: [(NSView, CGFloat)] = []
        for (view, _) in targets where view.alphaValue != 1 { fades.append((view, 1)) }
        for (view, _) in appearing { fades.append((view, 1)) }
        for (view, _) in leaving { fades.append((view, 0)) }
        return fades
    }

    /// One move of the rows (perf step 4, Leo 2026-10-21: "adding a workspace at the top ... it pushes all the stuff
    /// down"): every frame goes on the render server's `.move` spring from one begin time (`SidebarDragSpring`), so
    /// the rows below an insert move as one with the row opening above them, and no row's frame is written on the
    /// main thread per display frame (AppKit's SwiftUI spring wrote each moving row's frame every frame). Only the
    /// opacity of the few rows that open, close or still fade runs on AppKit's `.move` spring, with the group lines'
    /// fades (`lines`). `ended` runs once both have ended, or at once when the display sleeps (`settleAtSleep`).
    /// `companions`: the group lines and chat history blocks, on the same springs in the same transaction, so the
    /// springs' leg (and the display's sleep) waits for them too, even when no row moves (a line growing offscreen).
    private static func animate(frames: [(SidebarRowView, NSRect)], companions: [(NSView, NSRect)], fades: [(NSView, CGFloat)],
                                lines: () -> Void, in list: SidebarListView, ended: RowMotionEnd) {
        let settle = Self.settle(list)
        // Nothing draws while the display sleeps: the rows, group lines and history blocks show their places now, the
        // springs gone with the move. Both legs carry it, and it runs once: the opacity leg alone ends at once when
        // nothing fades (a reorder of opaque rows), while the springs still run.
        let settleAtSleep: @MainActor () -> Void = { [weak list] in
            guard !ended.isDone else { return }
            SidebarDragSpring.stop(frames.map(\.0))
            if let list {
                list.groupLineViews.stopSprings()
                SidebarDragSpring.stop(list.chatHistory.all)
            }
            settle()
            ended.finish()
        }
        let springsEnded = Motion.sidebar.trackMove(.move, settleAtSleep: settleAtSleep, completion: { ended.arrive() })
        CATransaction.begin()
        // Runs once every spring added in this transaction has ended or was removed (a reused view, a snap).
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { springsEnded() } } // main-proof: CATransaction.h: the completion block is called on the main thread
        SidebarDragSpring.move(frames.map { ($0.0 as NSView, $0.1) } + companions, in: list)
        Motion.sidebar.animate(.move, in: list, {
            for (view, alpha) in fades { view.animator().alphaValue = alpha }
            lines()
        }, settleAtSleep: settleAtSleep, completion: { ended.arrive() })
        CATransaction.commit()
    }

    /// Puts every row and group line exactly on its layout frame once the last move ended. A move on
    /// the render server's springs (`animate`) set the model frames at once, so this changes nothing
    /// after one; a frame AppKit's SwiftUI spring wrote stops within its rest tolerance, not on the
    /// target: rows stayed half a point off on a 1x screen (aws-m4pro-8), a fraction on Retina.
    /// A drag, a settling drop or a card's flight owns the frames until it ends.
    static func land(_ list: SidebarListView) {
        guard list.drag == nil, list.settling == nil, list.landing == nil else { return }
        Motion.withoutAnimation {
            for (key, view) in list.rowViews where view.closingEnd == nil {
                guard let row = list.displayed.row(for: key) else { continue }
                let target = list.frame(for: row)
                if view.frame != target { view.frame = target }
            }
            list.groupLineViews.land()
        }
    }

    /// Moves every row by `dy` at once, with the scroll offset (the anchor step of
    /// `SidebarListView.applyKeepingViewport`). A row still closing its slot from an earlier
    /// change moves too, and its close re-targets to its shifted end, so it keeps closing in
    /// place beside its neighbors instead of jumping by `dy` against them (cx-y2uf5).
    static func shift(_ list: SidebarListView, by dy: CGFloat) {
        let closing = list.subviews.compactMap { $0 as? SidebarRowView }.filter { $0.closingEnd != nil && !$0.isHidden }
        Motion.withoutAnimation {
            for view in list.rowViews.values { view.frame.origin.y += dy }
            for view in closing {
                view.frame.origin.y += dy
                view.closingEnd?.origin.y += dy
            }
        }
        // A close on the render server's spring (`animate`) already has its frame at its end, which moved with it:
        // its spring keeps running on top. Only a close whose frame is not at its end re-targets here.
        let retargeted = closing.filter { view in view.closingEnd.map { view.frame != $0 } ?? false }
        guard !retargeted.isEmpty else { return }
        // The close's own completion (`run`) still recycles each row.
        Motion.sidebar.animate(.move, in: list, {
            for view in retargeted {
                guard let end = view.closingEnd else { continue }
                view.animator().alphaValue = 0
                view.animator().frame = end
            }
        })
    }

    /// A row whose close ended (or never animated) goes back to the pool.
    private static func closed(_ view: SidebarRowView, in list: SidebarListView) {
        view.closingEnd = nil
        list.recycle(view)
    }

    /// Places a row that scrolled into view. One still opening (the viewport
    /// held still for an insert above it, then scrolled to it) opens from zero
    /// height at its slot instead of showing whole over the rows still making
    /// room (cx-ai79).
    static func place(_ view: SidebarRowView, at target: NSRect, opening: Bool, hidden: Bool, in list: SidebarListView) {
        untuck([view]) // a parked tab line kept from a fold comes back in order, not behind the rows
        guard opening, !hidden, Motion.sidebar.animatesMovement else {
            view.frame = target
            view.alphaValue = hidden ? 0 : 1
            return
        }
        Motion.withoutAnimation {
            view.frame = NSRect(x: target.minX, y: target.minY, width: target.width, height: 0)
            view.alphaValue = 0
            view.clipsToBounds = true
        }
        view.opens += 1
        let open = view.opens
        list.rowMoves &+= 1
        let move = list.rowMoves
        let ended = RowMotionEnd { [view, weak list] in
            if view.opens == open { view.clipsToBounds = false }
            if let list, list.rowMoves == move { Self.land(list) }
        }
        animate(frames: [(view, target)], companions: [], fades: [(view, 1)], lines: {}, in: list, ended: ended)
    }

    /// When the display sleeps mid-move (no frame draws, so the move never ends), the rows
    /// take the places the list holds then, without motion: a reload, never the targets this
    /// move captured, which a newer change may have replaced. Rows still leaving go in the
    /// move's completion, which runs right after.
    private static func settle(_ list: SidebarListView) -> @MainActor () -> Void {
        { [weak list] in list?.reload(animated: false) }
    }

    /// A moved selected row (with its workspace's tab rows) passes over the
    /// rows it trades places with: it draws above them, and each row it
    /// crosses hides at once and fades back in once the move has nearly
    /// settled, so a translucent selection fill never shows a title through
    /// it (cx-bqm6, cx-ai79).
    private func passOver(in list: SidebarListView, from old: SidebarLayout, to layout: SidebarLayout) {
        // A dragged row is hidden under its lifted card, which already draws
        // above the list: no row passes under it, so none hides (cx-ikxz).
        // A row still opening (listed, then placed: New Workspace in New Group) draws nothing yet
        // to pass over with: the rows it crosses stay as they are.
        guard let key = list.selectedRowKey, !list.suppressed.contains(key), !appearing.contains(where: { $0.0.key == key }),
              let before = old.row(for: key)?.y, let after = layout.row(for: key)?.y, before != after else { return }
        let block = Self.block(of: key)
        let passed = targets.map(\.0).filter { view in
            guard !block(view.key), let was = old.row(for: view.key)?.y, let now = layout.row(for: view.key)?.y else { return false }
            return (was < before) != (now < after)
        }
        // Only a block that crosses rows is raised: re-adding a view delays its
        // first frames, so a row an insert pushes down would lag the new row
        // opening above it (cx-ai79).
        guard !passed.isEmpty else { return }
        if let top = list.subviews.last(where: { $0 is SidebarRowView }) {
            var anchor = top
            for row in layout.rows where block(row.key) {
                guard let view = list.rowViews[row.key], view !== anchor else { continue }
                list.addSubview(view, positioned: .above, relativeTo: anchor)
                anchor = view
            }
        }
        for view in passed {
            guard let hide = Motion.sidebar.passOverAnimation(.move) else { return }
            view.layer?.add(hide, forKey: "cmux.passOver")
        }
    }

    /// The rows that move with `key`: a workspace and its tab rows.
    private static func block(of key: SidebarRowKey) -> (SidebarRowKey) -> Bool {
        let workspace: WorkspaceID? = switch key {
        case let .workspace(id), let .tab(id, _): id
        default: nil
        }
        return { candidate in
            if candidate == key { return true }
            guard let workspace else { return false }
            switch candidate {
            case let .workspace(id), let .tab(id, _): return id == workspace
            default: return false
            }
        }
    }
}

/// A row move's end (`RowMotion.animate`), run once: when both its legs have ended (the render server's
/// frame springs and AppKit's opacity spring), or at once when the display sleeps (`finish`), which
/// either leg's sleep settle runs (the first one; `isDone` skips the other). One per move,
/// with nothing to cancel: a later move makes its own, and the end lands rows only for the newest move.
@MainActor
final class RowMotionEnd {
    private var waiting = 2
    private var body: (@MainActor () -> Void)?

    init(_ body: @escaping @MainActor () -> Void) { self.body = body }

    /// One leg ended; the second runs the end.
    func arrive() {
        waiting -= 1
        if waiting <= 0 { finish() }
    }

    /// The end ran (both legs arrived, or the display slept).
    var isDone: Bool { body == nil }

    /// Runs the end now, once (a later arrival does nothing).
    func finish() {
        let body = self.body
        self.body = nil
        body?()
    }
}
