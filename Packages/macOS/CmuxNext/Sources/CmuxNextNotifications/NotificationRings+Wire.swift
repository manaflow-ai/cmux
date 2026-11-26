package import CmuxNextDaemon
import CmuxNextDesign
package import CmuxNextSettings
import CmuxNextWindowRules

/// What cmux-window-rules `notification_rings` answers (ops `notification_rings_*`): which panes ring and
/// with what generation, which looks read a tab, what Dismiss Highlight and a turn end record, where an
/// arriving notification goes, whether a reply may type and a workspace mark goes out. No rule lives
/// here: the notification service reads its models and view state into facts and applies the answer. A
/// rule that does not answer (a pinned FFI without the op) falls back to doing the least: no ring, no
/// read, a delivery.
package enum NotificationRings {
    /// One tab's facts (`notification_rings::Tab`).
    package nonisolated struct Tab: Encodable {
        var hasUnread: Bool
        var notification: UInt64?
        var markedUnread: Bool
        var markedGeneration: UInt64
        var dismissedMark: UInt64
        var attention: Bool
        var attentionHidden: Bool
        var attentionGeneration: UInt64
        var agentChat: Bool
        var working: Bool
        var finished: UInt64?
        var quiet: Bool
        var viewed: Bool
        var held: Bool
        var entryRead: Bool
        var keyMayRead: Bool
        var clearsSource: Bool

        /// `t`'s own facts under `trigger` (its key read only for a keystroke), with the service's view state.
        @MainActor
        package init(_ t: TabModel, _ trigger: NotificationTrigger, dismissedMark: UInt64, attentionHidden: Bool, working: Bool,
                     finished: UInt64?, quiet: Bool, viewed: Bool, held: Bool, entryRead: Bool, clearsSource: Bool) {
            hasUnread = t.hasUnread
            notification = t.notification?.notification.rawValue
            markedUnread = t.markedUnread
            markedGeneration = t.markedUnreadGeneration
            self.dismissedMark = dismissedMark
            attention = t.attention != nil
            self.attentionHidden = attentionHidden
            attentionGeneration = t.attentionGeneration
            agentChat = t.agentSession != nil
            self.working = working
            self.finished = finished
            self.quiet = quiet
            self.viewed = viewed
            self.held = held
            self.entryRead = entryRead
            keyMayRead = trigger == .keystroke ? t.keyMayRead() : true
            self.clearsSource = clearsSource
        }
    }

    /// The policy the read rules read under a trigger.
    package nonisolated struct Policy: Encodable {
        var clearsAgent: Bool
        var ringsChat: Bool

        @MainActor
        package init(_ trigger: NotificationTrigger, prefs: NotificationPreferences) {
            clearsAgent = NotificationPolicy(prefs: prefs).clears(trigger, for: .agent)
            ringsChat = DesignSettings.shared.attention.rings(agentChat: true)
        }
    }

    nonisolated struct RingAsk: Encodable {
        var tab: Tab
        var dismissed: UInt64
    }

    nonisolated struct RingReply: Decodable {
        var generation: String?
    }

    nonisolated struct ReadsAsk: Encodable {
        var trigger: String
        var tab: Tab
        var turn: Bool
        var onSight: Bool
        var policy: Policy
    }

    nonisolated struct ReadsReply: Decodable {
        var reads: Bool
    }

    package nonisolated struct ShownPane: Encodable {
        var pane: String
        var tab: Tab

        package init(pane: String, tab: Tab) {
            self.pane = pane
            self.tab = tab
        }
    }

    nonisolated struct MarksAsk: Encodable {
        var styleNone: Bool
        var muted: Bool
        var local: Bool
        var dismissed: UInt64
        var policy: Policy
        var ringsTerminal: Bool
        var panes: [ShownPane]
    }

    /// A pane that rings; `color`: "agent", "source" or "ring" (the ring's own).
    package nonisolated struct PaneMark: Decodable {
        package var pane: String
        package var generation: String
        package var agentChat: Bool
        package var quiet: Bool
        package var color: String
    }

    nonisolated struct MarksReply: Decodable {
        var marks: [PaneMark]
    }

    package nonisolated struct EntryPane: Encodable {
        var pane: String
        var tabs: [Tab]

        package init(pane: String, tabs: [Tab]) {
            self.pane = pane
            self.tabs = tabs
        }
    }

    nonisolated struct EntryAsk: Encodable {
        var removed: [String]
        var flashesOnFocus: Bool
        var anyEntryReads: Bool
        var policy: Policy
        var panes: [EntryPane]
    }

    nonisolated struct EntryReply: Decodable {
        var panes: [String]
    }

    nonisolated struct InteractionAsk: Encodable {
        var trigger: String
        var local: Bool
        var ownerCannotAck: Bool
        var flashes: Bool
        var policy: Policy
        var tab: Tab
    }

    /// One look's plan (`notification_rings::Interaction`), in the order it is applied; `ack`: "none",
    /// "refused" (the owner cannot take an ack) or "read".
    package nonisolated struct Interaction: Decodable {
        package var endsHold: Bool
        package var seesWorkspace: Bool
        package var readsTurn: Bool
        package var hidesAttention: Bool
        package var readsMark: Bool
        package var ack: String
        package var entryRead: Bool
    }

    nonisolated struct HighlightAsk: Encodable {
        var local: Bool
        var flashesOnRead: Bool
        var dismissed: UInt64
        var tabs: [Tab]
    }

    /// What Dismiss Highlight does to the tab at `index` of the tabs asked about.
    package nonisolated struct HighlightStep: Decodable {
        package var index: Int
        package var clearsTurn: Bool
        package var hidesMark: UInt64?
        package var hidesAttention: Bool
        package var entryRead: Bool
    }

    /// Dismiss Highlight's plan; `through`: the newest notification id it dismisses.
    package nonisolated struct Highlight: Decodable {
        package var steps: [HighlightStep]
        package var through: UInt64?
    }

    nonisolated struct TurnEndAsk: Encodable {
        var rings: Bool
        var sincePulseMs: Double?
        var generation: UInt64
        var viewed: [Bool]
    }

    /// The tab at `index` of the chat's tabs rings its finished turn with `generation`.
    package nonisolated struct TurnRing: Decodable {
        package var index: Int
        package var generation: UInt64
        package var quiet: Bool
    }

    /// What a turn end records: its rings, the next generation, and whether it pulsed.
    package nonisolated struct TurnEnd: Decodable {
        package var rings: [TurnRing]
        package var generation: UInt64
        package var pulsed: Bool
    }

    nonisolated struct ReplyAsk: Encodable {
        var banner: String
        var textEmpty: Bool
        var located: Bool
        var pty: Bool
        var marker: UInt64?
        var markerUnread: Bool
    }

    nonisolated struct ReplyReply: Decodable {
        var allowed: Bool
    }

    nonisolated struct ArrivalAsk: Encodable {
        var terminalOff: Bool
        var located: Bool
        var acknowledge: Bool
        var finishedTurn: Bool
        var visible: Bool
        var holdsOtherAsk: Bool
        var clearsFocus: Bool
        var program: Bool
        var terminalSource: Bool
        var looksLikeAlert: Bool
    }

    nonisolated struct ProgramSeenAsk: Encodable {
        var clearsFocus: Bool
    }

    /// Where an arriving notification goes (`notification_rings::ArrivalRoute`).
    package nonisolated enum Route: String, Decodable {
        case terminalOff
        case untracked
        case readOnSight
        case keepSeen
        case readSeen
        case holdForRecord
        case deliver
    }

    nonisolated struct RouteReply: Decodable {
        var route: Route
    }

    nonisolated struct LastSend: Encodable {
        var marked: Bool
        var agoMs: Double
    }

    nonisolated struct MarkSendAsk: Encodable {
        var marked: Bool
        var current: Bool
        var last: LastSend?
        var throttled: Bool
    }

    nonisolated struct MarkSendReply: Decodable {
        var send: Bool
    }

    /// Whether a look with `trigger` reads `tab` (`turn`: its finished turn counts), or on sight.
    package nonisolated static func reads(_ trigger: NotificationTrigger, _ tab: Tab, turn: Bool, onSight: Bool, policy: Policy) -> Bool {
        let ask = ReadsAsk(trigger: trigger.rawValue, tab: tab, turn: turn, onSight: onSight, policy: policy)
        return WindowRules().call("notification_rings_reads", ask, as: ReadsReply.self)?.reads ?? false
    }

    /// The ring generation of `tab` (nil: none), with the workspace's newest dismissed notification id.
    package nonisolated static func ring(_ tab: Tab, dismissed: UInt64) -> UInt64? {
        let reply = WindowRules().call("notification_rings_ring", RingAsk(tab: tab, dismissed: dismissed), as: RingReply.self)
        return reply?.generation.flatMap { UInt64($0) }
    }

    /// The shown panes that ring; none when the rule does not answer.
    package nonisolated static func marks(local: Bool, dismissed: UInt64, policy: Policy, ringsTerminal: Bool, panes: [ShownPane]) -> [PaneMark] {
        let ask = MarksAsk(styleNone: false, muted: false, local: local, dismissed: dismissed, policy: policy, ringsTerminal: ringsTerminal, panes: panes)
        return WindowRules().call("notification_rings_marks", ask, as: MarksReply.self)?.marks ?? []
    }

    /// The panes whose ring blinks out on entry; none when the rule does not answer.
    package nonisolated static func entered(removed: [String], flashesOnFocus: Bool, anyEntryReads: Bool, policy: Policy,
                                            panes: [EntryPane]) -> [String] {
        let ask = EntryAsk(removed: removed, flashesOnFocus: flashesOnFocus, anyEntryReads: anyEntryReads, policy: policy, panes: panes)
        return WindowRules().call("notification_rings_entered", ask, as: EntryReply.self)?.panes ?? []
    }

    /// One look's plan; nothing when the rule does not answer.
    package nonisolated static func interaction(_ trigger: NotificationTrigger, local: Bool, ownerCannotAck: Bool, flashes: Bool,
                                                policy: Policy, tab: Tab) -> Interaction {
        let ask = InteractionAsk(trigger: trigger.rawValue, local: local, ownerCannotAck: ownerCannotAck, flashes: flashes, policy: policy, tab: tab)
        return WindowRules().call("notification_rings_interaction", ask, as: Interaction.self)
            ?? Interaction(endsHold: false, seesWorkspace: false, readsTurn: false, hidesAttention: false, readsMark: false, ack: "none", entryRead: false)
    }

    /// Dismiss Highlight's plan; it reads nothing when the rule does not answer.
    package nonisolated static func dismissHighlight(local: Bool, flashesOnRead: Bool, dismissed: UInt64, tabs: [Tab]) -> Highlight {
        let ask = HighlightAsk(local: local, flashesOnRead: flashesOnRead, dismissed: dismissed, tabs: tabs)
        return WindowRules().call("notification_rings_dismiss_highlight", ask, as: Highlight.self) ?? Highlight(steps: [], through: nil)
    }

    /// What a turn end records; nothing when the rule does not answer.
    package nonisolated static func turnEnded(rings: Bool, sincePulseMs: Double?, generation: UInt64, viewed: [Bool]) -> TurnEnd {
        let ask = TurnEndAsk(rings: rings, sincePulseMs: sincePulseMs, generation: generation, viewed: viewed)
        return WindowRules().call("notification_rings_turn_ended", ask, as: TurnEnd.self) ?? TurnEnd(rings: [], generation: generation, pulsed: false)
    }

    /// Whether a reply banner may type; refused when the rule does not answer.
    package nonisolated static func replyAllowed(banner: String, textEmpty: Bool, located: Bool, pty: Bool, marker: UInt64?,
                                                 markerUnread: Bool) -> Bool {
        let ask = ReplyAsk(banner: banner, textEmpty: textEmpty, located: located, pty: pty, marker: marker, markerUnread: markerUnread)
        return WindowRules().call("notification_rings_reply", ask, as: ReplyReply.self)?.allowed ?? false
    }

    /// Where an arrival goes; delivered (read, with terminal notifications off) when the rule does not answer.
    package nonisolated static func arrival(terminalOff: Bool, located: Bool, acknowledge: Bool, finishedTurn: Bool, visible: Bool,
                                            holdsOtherAsk: Bool, clearsFocus: Bool, program: Bool, terminalSource: Bool,
                                            looksLikeAlert: Bool) -> Route {
        let ask = ArrivalAsk(terminalOff: terminalOff, located: located, acknowledge: acknowledge, finishedTurn: finishedTurn, visible: visible,
                             holdsOtherAsk: holdsOtherAsk, clearsFocus: clearsFocus, program: program, terminalSource: terminalSource,
                             looksLikeAlert: looksLikeAlert)
        return WindowRules().call("notification_rings_arrival", ask, as: RouteReply.self)?.route ?? (terminalOff ? .terminalOff : .deliver)
    }

    /// A notification the person saw land: read at once, or kept unread for a click (when the rule
    /// does not answer: kept, posting nothing).
    package nonisolated static func programSeen(clearsFocus: Bool) -> Route {
        WindowRules().call("notification_rings_program_seen", ProgramSeenAsk(clearsFocus: clearsFocus), as: RouteReply.self)?.route ?? .keepSeen
    }

    /// Whether a workspace's Mark as Unread `marked` goes out over a tree saying `current`, its last send
    /// `last` (`ago` before now); a rule that does not answer sends when the tree differs.
    package nonisolated static func markSend(_ marked: Bool, current: Bool, last: (marked: Bool, ago: Duration)?, throttled: Bool) -> Bool {
        let sent = last.map { LastSend(marked: $0.marked, agoMs: Double($0.ago.components.seconds) * 1000 + Double($0.ago.components.attoseconds) / 1e15) }
        let ask = MarkSendAsk(marked: marked, current: current, last: sent, throttled: throttled)
        return WindowRules().call("notification_rings_mark_send", ask, as: MarkSendReply.self)?.send ?? (current != marked)
    }
}
