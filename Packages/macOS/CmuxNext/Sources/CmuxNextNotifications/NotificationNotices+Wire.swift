package import CmuxNextDesign
package import CmuxNextSettings
import CmuxNextWindowRules

/// The notices' rules, asked of cmux-window-rules `notification_notices` over the app FFI's JSON
/// channel (ops `notification_notices_*`): a Cloud hand-off's and a sandboxed Run's banner, the
/// Needs you banner's Show, Mark Tab Unread's toggle, the tab a pane shows and the entry blink.
/// The app reads its models into facts, asks here, and does what the answer says. Each call has a
/// safe answer when the FFI does not answer (logged by ``WindowRules``): no banner, no write, no blink.
package nonisolated enum NotificationNotices {
    /// Which notice a banner is.
    package enum Notice: String, Codable, Sendable {
        case handoff
        case sandboxRun
        case attention
    }

    /// The sound event a notice's arrival is decided under. `outcome` is the Run's or hand-off's
    /// `SandboxRunEnd.Outcome` raw value; `classified` a Needs you banner's classified sound.
    package static func soundEvent(_ notice: Notice, outcome: String = "failed",
                                   classified: NotificationSoundEvent? = nil) -> NotificationSoundEvent {
        let request = SoundRequest(notice: notice, outcome: outcome, classified: classified?.rawValue)
        let reply = WindowRules().call("notification_notices_sound", request, as: SoundReply.self)
        return reply.flatMap { NotificationSoundEvent(rawValue: $0.soundEvent) } ?? (notice == .attention ? classified ?? .needsInput : .error)
    }

    /// Whether a decided notice goes on to the sound gate and delivery.
    package static func goesOn(acknowledge: Bool, postingEnabled: Bool) -> Bool {
        let request = GoesOnRequest(acknowledge: acknowledge, postingEnabled: postingEnabled)
        return WindowRules().call("notification_notices_goes_on", request, as: GoesOnReply.self)?.goesOn ?? false
    }

    /// How a decided notice is delivered.
    package struct Delivery: Decodable, Equatable, Sendable {
        /// A banner is posted.
        package var banner: Bool
        /// The banner carries the system's default sound.
        package var defaultSound: Bool
        /// The app plays the decided sound itself, with `banner: play`; nil: it plays none.
        package var play: Bool?
    }

    /// The delivery of a decision whose banner mode is `desktop` and whose sound is `sound`.
    package static func delivery(desktop: Bool, sound: String?) -> Delivery {
        let request = DeliveryRequest(desktop: desktop, sound: sound)
        return WindowRules().call("notification_notices_delivery", request, as: Delivery.self)
            ?? Delivery(banner: desktop, defaultSound: false, play: nil)
    }

    /// A hand-off banner's words, before the app words its state.
    package struct HandoffText: Decodable, Equatable, Sendable {
        /// What the banner's state line says.
        package enum State: String, Decodable, Sendable {
            case needsYou
            case done
            case failed
        }

        /// The chat's title, else the summary's first line; nil: the app's untitled name.
        package var title: String?
        /// The state line; nil only when the FFI did not answer.
        package var state: State?
        /// The summary under the state line.
        package var detail: String?
    }

    /// A hand-off banner's words for an end with `outcome`, its wait's `summary` (else the
    /// record's `task`) and the title of the `chat` showing it.
    package static func handoffText(outcome: String, summary: String?, task: String, chat: String?) -> HandoffText {
        let request = HandoffTextRequest(outcome: outcome, summary: summary, task: task, chat: chat)
        return WindowRules().call("notification_notices_handoff_text", request, as: HandoffText.self)
            ?? HandoffText(title: nil, state: nil, detail: nil)
    }

    /// A Run banner's words, before the app words its body.
    package struct RunText: Decodable, Equatable, Sendable {
        /// How the Run ended, as its body line says.
        package enum Body: String, Decodable, Sendable {
            case succeeded
            case failed
            case timedOut
            case cancelled
        }

        /// The task's first line.
        package var title: String
        /// The body line; nil only when the FFI did not answer.
        package var body: Body?
    }

    /// A Run banner's words for `task`, which ended with `outcome`.
    package static func sandboxRunText(task: String, outcome: String) -> RunText {
        let request = RunTextRequest(task: task, outcome: outcome)
        return WindowRules().call("notification_notices_sandbox_run_text", request, as: RunText.self)
            ?? RunText(title: "", body: nil)
    }

    /// The notice banner `id` names and its own id (a hand-off's, a Run's, a tab's); nil for any other banner.
    package static func banner(_ id: String) -> (notice: Notice, id: String)? {
        let reply = WindowRules().call("notification_notices_banner", BannerRequest(banner: id), as: BannerReply.self)
        return reply?.banner.map { ($0.notice, $0.id) }
    }

    /// What a hand-off banner's click does once the tab showing its chat was tried.
    package enum HandoffOpen: String, Decodable, Sendable {
        case nothing
        case activate
        case openWorkspace
    }

    /// A hand-off banner's click: `found` its record, `revealed` a tab showing its chat,
    /// `incognito` its chat, `hasHost` its session's host.
    package static func handoffOpen(found: Bool, revealed: Bool, incognito: Bool, hasHost: Bool) -> HandoffOpen {
        let request = HandoffOpenRequest(found: found, revealed: revealed, incognito: incognito, hasHost: hasHost)
        return WindowRules().call("notification_notices_handoff_open", request, as: HandoffOpenReply.self)?.open ?? .nothing
    }

    /// What a Run banner's click does.
    package enum RunOpen: String, Decodable, Sendable {
        case nothing
        case showTab
        case newWorkspace
    }

    /// A Run banner's click: `found` the ended Run, `stale` its page, `tab` the tab that sent it, `incognito` its chat.
    package static func sandboxRunOpen(found: Bool, stale: Bool, tab: Bool, incognito: Bool) -> RunOpen {
        let request = RunOpenRequest(found: found, stale: stale, tab: tab, incognito: incognito)
        return WindowRules().call("notification_notices_sandbox_run_open", request, as: RunOpenReply.self)?.open ?? .nothing
    }

    /// What Show on a Needs you banner does.
    package enum AttentionShow: String, Decodable, Sendable {
        /// The banner is no Needs you banner's.
        case notOurs
        /// The app's services have not started.
        case nothing
        /// This launch did not post it, or its request is no longer the tab's mark.
        case gone
        /// Open the tab.
        case open
    }

    /// Show on Needs you banner `banner`: `shared` the marked-tab list is there, `posted` this
    /// launch posted it, `marked` the marked tabs' row keys. The answer and the tab the banner names.
    package static func attentionShow(banner: String, shared: Bool, posted: Bool, marked: [String]) -> (show: AttentionShow, tab: String?) {
        let request = AttentionShowRequest(banner: banner, shared: shared, posted: posted, marked: marked)
        guard let reply = WindowRules().call("notification_notices_attention_show", request, as: AttentionShowReply.self) else {
            return (.notOurs, nil)
        }
        return (reply.show, reply.tab)
    }

    /// The capability a mark write needs (`DaemonCapability` raw values are the app's).
    package enum MarkCapability: String, Decodable, Sendable {
        case tabAttentionRequestId
        case tabMarkUnread
    }

    /// One write of Mark Tab Unread's toggle, in order.
    package enum MarkStep: String, Decodable, Sendable {
        /// Acknowledge the tab's notification.
        case acknowledge
        /// Clear the manual mark.
        case clearMark
        /// Clear the agent's needs-you request.
        case clearAttention
        /// Mark the tab unread.
        case mark
    }

    /// Mark Tab Unread's toggle: the refusal, else its writes in order.
    package struct TogglePlan: Decodable, Equatable, Sendable {
        /// The capability the tab's daemon lacks; nothing is written.
        package var refuse: MarkCapability?
        /// The writes, in order.
        package var steps: [MarkStep]
    }

    /// The toggle of a tab that `showsUnread`, `hasUnread` (a notification), is `markedUnread`, has
    /// an agent's request (`attention`), on a daemon that keeps conditional attention clears
    /// (`attentionSupported`) and the mark (`markSupported`).
    package static func tabUnreadToggle(showsUnread: Bool, hasUnread: Bool, markedUnread: Bool, attention: Bool,
                                        attentionSupported: Bool, markSupported: Bool) -> TogglePlan {
        let request = ToggleRequest(showsUnread: showsUnread, hasUnread: hasUnread, markedUnread: markedUnread, attention: attention,
                                    attentionSupported: attentionSupported, markSupported: markSupported)
        return WindowRules().call("notification_notices_tab_unread_toggle", request, as: TogglePlan.self)
            ?? TogglePlan(refuse: nil, steps: [])
    }

    /// One mark write on its own.
    package enum MarkWrite: String, Encodable, Sendable {
        case mark
        case clearMark
        case clearAttention
    }

    /// What one mark write does on a daemon that does or does not keep it.
    package enum WriteStep: Equatable, Sendable {
        case send
        case nothing
        case refuse(MarkCapability)
    }

    /// Whether `write` is sent, skipped, or refused on a daemon that keeps it when `supported`.
    package static func markWrite(_ write: MarkWrite, supported: Bool) -> WriteStep {
        guard let reply = WindowRules().call("notification_notices_tab_unread_write", WriteRequest(write: write, supported: supported),
                                             as: WriteReply.self) else { return .nothing }
        switch reply.step {
        case "send": return .send
        case "refuse": return reply.capability.map(WriteStep.refuse) ?? .nothing
        default: return .nothing
        }
    }

    /// The ids of `viewed` tabs `previous` did not hold: the tabs that came into view.
    package static func entered(_ viewed: [String], previous: Set<String>) -> [String] {
        let request = EnteredRequest(viewed: viewed, previous: previous.sorted())
        return WindowRules().call("notification_notices_tab_unread_entered", request, as: EnteredReply.self)?.entered ?? []
    }

    /// The index of the tab a pane of `count` tabs shows: the window's `selected` one, else the
    /// daemon's default `defaultIndex`; nil for a pane with no tabs.
    package static func shownIndex(count: Int, selected: Int? = nil, defaultIndex: Int) -> Int? {
        guard count > 0 else { return nil }
        let request = ShownTabRequest(count: count, selected: selected.map { max($0, 0) }, defaultIndex: defaultIndex)
        let index = WindowRules().call("notification_notices_shown_tab", request, as: ShownTabReply.self)?.index
        return index.flatMap { (0..<count).contains($0) ? $0 : nil } ?? 0
    }
}

package nonisolated extension AttentionSettings {
    /// Whether reading a pane by `trigger` flashes its ring as it goes: going into it (focusing
    /// it, a click, a key, an open), as in classic, where focusing a pane with an unread
    /// notification played its dismiss flash (https://github.com/manaflow-ai/cmux/issues/42210),
    /// unless `notifications.attention.flash` is off, or the key under `flashOnTyping` off.
    package func flashesOnEntry(_ trigger: NotificationTrigger) -> Bool {
        let request = EntryRequest(trigger: trigger.rawValue, flashesOnRead: flashesOnRead, flashesOnTyping: flashesOnTyping)
        return WindowRules().call("notification_notices_flashes_on_entry", request, as: EntryReply.self)?.flashes ?? false
    }
}

private nonisolated struct SoundRequest: Encodable {
    var notice: NotificationNotices.Notice
    var outcome: String
    var classified: String?
}

private nonisolated struct SoundReply: Decodable {
    var soundEvent: String
}

private nonisolated struct GoesOnRequest: Encodable {
    var acknowledge: Bool
    var postingEnabled: Bool
}

private nonisolated struct GoesOnReply: Decodable {
    var goesOn: Bool
}

private nonisolated struct DeliveryRequest: Encodable {
    var desktop: Bool
    var sound: String?
}

private nonisolated struct HandoffTextRequest: Encodable {
    var outcome: String
    var summary: String?
    var task: String
    var chat: String?
}

private nonisolated struct RunTextRequest: Encodable {
    var task: String
    var outcome: String
}

private nonisolated struct BannerRequest: Encodable {
    var banner: String
}

private nonisolated struct BannerReply: Decodable {
    struct Banner: Decodable {
        var notice: NotificationNotices.Notice
        var id: String
    }

    var banner: Banner?
}

private nonisolated struct HandoffOpenRequest: Encodable {
    var found: Bool
    var revealed: Bool
    var incognito: Bool
    var hasHost: Bool
}

private nonisolated struct HandoffOpenReply: Decodable {
    var open: NotificationNotices.HandoffOpen
}

private nonisolated struct RunOpenRequest: Encodable {
    var found: Bool
    var stale: Bool
    var tab: Bool
    var incognito: Bool
}

private nonisolated struct RunOpenReply: Decodable {
    var open: NotificationNotices.RunOpen
}

private nonisolated struct AttentionShowRequest: Encodable {
    var banner: String
    var shared: Bool
    var posted: Bool
    var marked: [String]
}

private nonisolated struct AttentionShowReply: Decodable {
    var show: NotificationNotices.AttentionShow
    var tab: String?
}

private nonisolated struct ToggleRequest: Encodable {
    var showsUnread: Bool
    var hasUnread: Bool
    var markedUnread: Bool
    var attention: Bool
    var attentionSupported: Bool
    var markSupported: Bool
}

private nonisolated struct WriteRequest: Encodable {
    var write: NotificationNotices.MarkWrite
    var supported: Bool
}

private nonisolated struct WriteReply: Decodable {
    var step: String
    var capability: NotificationNotices.MarkCapability?
}

private nonisolated struct EnteredRequest: Encodable {
    var viewed: [String]
    var previous: [String]
}

private nonisolated struct EnteredReply: Decodable {
    var entered: [String]
}

private nonisolated struct ShownTabRequest: Encodable {
    var count: Int
    var selected: Int?
    var defaultIndex: Int
}

private nonisolated struct ShownTabReply: Decodable {
    var index: Int?
}

private nonisolated struct EntryRequest: Encodable {
    var trigger: String
    var flashesOnRead: Bool
    var flashesOnTyping: Bool
}

private nonisolated struct EntryReply: Decodable {
    var flashes: Bool
}
