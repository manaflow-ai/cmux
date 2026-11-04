public import AppKit
import os

// The hold's own reply bound (cmux-ad m12) and the types its keys are handed on with; split from
// CreationInputBuffer.swift (its file was over the 400-line cap).
extension CreationInputBuffer {
    /// The longest a creation's reply keeps the window's keys (cmux-ad m12). A hold has its own bound, never the daemon
    /// transport's: #35075 raised the request deadline from 2 s to 30 s, and a hold that waited for the reply then kept
    /// the person's keys up to 30 s. Before it, the slowest holds (a new browser tab's keyed create, Cmd-N's room pin)
    /// ended when their late-reply budget gave up: `NewFrontendBrowserTabRequest.lateReplyBudget` (10 s) plus at most one
    /// 2 s deadline (5b72fdac44^). This is that budget, and it does not follow the request deadline.
    public static let replyWaitBound: Duration = .seconds(10)

    /// The bound that ended a hold (``onBound``).
    public enum Bound: Sendable { case limit, reply }

    /// The terminal a lane's keys are for: its tab, and the machine it is on when that was known.
    public struct HeldLane: Hashable, Sendable {
        public let tab: String
        public let machine: String?
        public init(tab: String, machine: String?) { self.tab = tab; self.machine = machine }
    }

    /// Held keys at the hold's end, in typing order (``take(focused:)``).
    public enum HeldKey {
        /// Keys of a lane whose terminal is not the focused one, in order, typed as one run (one daemon send when its
        /// view is gone, so no key passes another): that terminal's own key encoding, never the focused terminal (a held
        /// Ctrl-C must not stop another process). Chords that are no app shortcut (Ctrl-C, Ctrl-U) stay in the run.
        case type([NSEvent], lane: HeldLane)
        /// An app shortcut (Cmd-D, Ctrl-`, Ctrl-Tab) typed for a lane whose terminal is not the focused one: it runs with
        /// that terminal's tab as its target, as a key press there.
        case command(NSEvent, lane: HeldLane)
        /// A key that runs again as typed: the focused lane's (`lane`), or a key typed for no creation (nil).
        case run(NSEvent, lane: HeldLane?)

        /// Each key with the terminal it was typed for, in order (to hold them again, ``prepend(_:issuer:)``).
        public var keys: [(event: NSEvent, lane: HeldLane?)] {
            switch self {
            case .type(let events, let lane): events.map { ($0, lane) }
            case .command(let event, let lane): [(event, lane)]
            case .run(let event, let lane): [(event, lane)]
            }
        }

        /// The terminal the first key was typed for.
        public var lane: HeldLane? { keys.first?.lane }
    }

    /// A close whose question asks the person (``parkClose(_:)``); nil `ticket`: it holds no keys.
    public struct ParkedClose {
        public let ticket: Ticket?
        public init(ticket: Ticket?) { self.ticket = ticket }
    }

    /// Calls ``onBound`` with ``Bound/limit`` after `limit` unless a creation of this hold still waits for its reply then
    /// (its reply arms the bound again: the coordinator calls this from `resolve`).
    public func expire(after limit: Duration) {
        // task-owner: one-shot bound on this hold; a hold that ended first makes it a no-op
        Task { @MainActor [weak self] in
            // wakeup-allow: one-shot bound on a key hold, so a hold whose terminal never shows ends
            try? await Task.sleep(for: limit)
            guard let self, !hasPendingCreation else { return }
            onBound?(self, .limit)
        }
    }

    /// Held keys of a new workspace's terminal that never run: the log says how many and why.
    static func logDropped(_ count: Int, why: String) {
        guard count > 0 else { return }
        Logger(subsystem: "com.cmuxterm.app.next", category: "focus.creation-hold")
            .notice("\(count, privacy: .public) key(s) typed for a new workspace's terminal dropped: \(why, privacy: .public)")
    }

    /// Window `window` of the hold is gone: the keys held for a terminal, as runs for each terminal in typing order. A key
    /// held for no terminal had only that window and goes with it, logged (cmux-ad m12: no other key is dropped).
    public func takeForClosedWindow(window: Int) -> [([NSEvent], HeldLane)] {
        var runs: [([NSEvent], HeldLane)] = [], lost = -untypedTerminalKeys
        for key in take(focused: nil, isShortcut: { _, _ in false }) {
            if case .type(let events, let lane) = key { runs.append((events, lane)) } else { lost += key.keys.count }
        }
        lost += untypedTerminalKeys // and the keys of a new workspace asked for over no terminal
        if lost > 0 {
            Logger(subsystem: "com.cmuxterm.app.next", category: "focus.creation-hold")
                .notice("creation hold of closed window \(window, privacy: .public): \(lost, privacy: .public) held key(s) for no terminal went with it")
        }
        return runs
    }

    /// Whether this hold keeps `event`.
    ///
    /// - A close key (`closes`: its binding is a close action, Cmd-W) never waits: it acts at once on
    ///   what it closes, a pending creation included (TabLifecycle cancels it). Held, it ran later
    ///   with the other held keys and closed the next tab, then the window (macOS 15 tester,
    ///   2026-10-19: Cmd-D then Cmd-W from Settings).
    /// - A creation waiting for its reply keeps every other key.
    /// - After the reply the hold ends `limit` later (`expiring`), even when the focus it asked for
    ///   never lands (a split from a page tab shows a New Tab page, not a terminal).
    /// - A hold that only waits for a selected terminal's surface ends `limit` after it began, and
    ///   lets a chord through while it holds nothing (held Ctrl-Tab makes no surface for a tab it passed).
    /// - `replyLimit`: the longest a creation waiting for its reply keeps the keys (``replyWaitBound``).
    public func holds(_ event: NSEvent, limit: Duration, expiring: Bool, closes: Bool = false, replyLimit: Duration? = nil) -> Bool {
        if closes { return false }
        if hasPendingCreation { return !waitedPastReplyBound(replyLimit) }
        if expiring, ContinuousClock.now - (lastReplyAt ?? began) >= limit { return false }
        if holdsCreation { return true }
        return !(isEmpty && !event.modifierFlags.intersection([.command, .control]).isEmpty)
    }
}
