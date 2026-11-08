import CmuxHomeCore
import Foundation

/// What one agent's chat in the agent pane shows (user 2026-11-03, msg 19960): its title and status, the
/// task as "Sent via Chief", "Worked for 5m 35s" with its details behind the ›, and every later message,
/// each named by its sender. Values only, so the view draws a real agent and the DEBUG playground's alike.
struct HomeAgentChatContent: Equatable, Sendable {
    /// Who wrote a message after the task.
    enum Sender: Equatable, Sendable {
        /// The agent itself (no label over it).
        case agent
        /// The Chief, through its `tell` tool.
        case chief
        /// The person, through the pane's composer.
        case you

        /// The pane's sender for a thread's ``HomeAgentSender``.
        init(_ sender: HomeAgentSender) {
            switch sender {
            case .agent: self = .agent
            case .chief: self = .chief
            case .you: self = .you
            }
        }

        /// The label over the message; nil for the agent's own.
        var label: String? {
            switch self {
            case .agent: nil
            case .chief: String(localized: "home.agentPane.sender.chief", defaultValue: "Chief", bundle: .module)
            case .you: String(localized: "home.agentPane.sender.you", defaultValue: "You", bundle: .module)
            }
        }
    }

    /// One message after the task.
    struct Message: Equatable, Sendable {
        var sender: Sender
        var text: String
    }

    /// The agent's id (`a12`).
    var peer: String
    /// The task's title.
    var title: String
    /// Queued, Working, Reported or Stopped without a report.
    var status: String
    /// The Chief's task (empty: no "Sent via Chief" bubble).
    var task: String
    /// "Worked for 5m 35s" (empty: no line).
    var workedFor: String
    /// The lines behind "Worked for ›" (when it started and ended).
    var details: [String]
    /// Every message after the task, oldest first.
    var messages: [Message]
    /// Where Go to workspace goes: the Chief's link to the agent's session, or the session's own link once
    /// it moved; nil hides the button.
    var workspaceLink: URL?
    /// The machine it moved to (a Chief move or `acpmux session move`); nil while it runs where it started.
    var place: String?
    /// True while it waits in the Chief's queue for a free slot (not started; no workspace yet).
    var isQueued = false
    /// How many queued agents start before it (0: it starts next); nil when not queued or not known.
    var ahead: Int?
    /// True after the person pressed Start now, until it starts (the button says Starting and takes no click).
    var isStarting = false

    /// Where it stands in the queue for the header ("Starts next", "2 ahead of it"); nil when not queued.
    var queueLine: String? {
        guard isQueued, let ahead else { return nil }
        if ahead == 0 { return String(localized: "home.agentPane.queueNext", defaultValue: "Starts next", bundle: .module) }
        return String(format: String(localized: "home.agentPane.queueAhead", defaultValue: "%lld ahead of it", bundle: .module), ahead)
    }
}

extension HomeAgentChatContent {
    /// The content of a real agent's chat.
    ///
    /// - Parameters:
    ///   - thread: The agent's chat with the Chief (``HomeStore/agentThread(_:in:)``).
    ///   - now: The current time, for a working agent's "Working for".
    ///   - session: Where its session runs, as followed (``HomeAgentSessionRef``); nil: not placed yet.
    init(_ thread: HomeAgentThread, now: Date, session: HomeAgentSessionRef? = nil) {
        let duration = Self.duration(thread.workedFor(now: now))
        let started = thread.startedAt.formatted(date: .omitted, time: .shortened)
        var details = [String(format: String(localized: "home.agentPane.started", defaultValue: "Started %@", bundle: .module), started)]
        if let ended = thread.endedAt?.formatted(date: .omitted, time: .shortened) {
            details.append(String(format: String(localized: "home.agentPane.finished", defaultValue: "Finished %@", bundle: .module), ended))
        }
        self.init(
            peer: thread.peer, title: thread.title, status: Self.status(thread.state), task: thread.task ?? "",
            workedFor: Self.timeLine(thread.state, duration: duration),
            details: details,
            messages: thread.entries.map { Message(sender: Sender($0.sender), text: $0.text) },
            workspaceLink: thread.workspaceLink)
        isQueued = thread.state == .queued
        // A started agent the Chief has not linked yet (one that waited in the queue): its session's own link.
        if workspaceLink == nil, !isQueued, let session, session.peer == thread.peer {
            workspaceLink = session.sessionLink
        }
        // Only this chat's session (a restarted agent has another); once it moved, its own link opens it
        // where acpmux has it now, not the Chief's link to where it started.
        if let session, session.session == thread.session, session.hasMoved {
            place = session.place
            workspaceLink = session.sessionLink ?? thread.workspaceLink
        }
    }

    /// The line over the steps: "Queued for 6m 50s" while it waits for a slot, "Working for …" while it works,
    /// else "Worked for …".
    static func timeLine(_ state: HomeAgentMessageRow.PeerState, duration: String) -> String {
        switch state {
        case .queued: String(format: String(localized: "home.agentPane.queuedFor", defaultValue: "Queued for %@", bundle: .module), duration)
        case .told: String(format: String(localized: "home.agentPane.workingFor", defaultValue: "Working for %@", bundle: .module), duration)
        case .reported, .stopped:
            String(format: String(localized: "home.agentPane.workedFor", defaultValue: "Worked for %@", bundle: .module), duration)
        }
    }

    /// The status words for `state`.
    static func status(_ state: HomeAgentMessageRow.PeerState) -> String {
        switch state {
        case .queued: String(localized: "home.agentPane.status.queued", defaultValue: "Queued", bundle: .module)
        case .told: String(localized: "home.agentPane.status.working", defaultValue: "Working", bundle: .module)
        case .reported: String(localized: "home.agentPane.status.reported", defaultValue: "Reported", bundle: .module)
        case .stopped: String(localized: "home.agentPane.status.stopped", defaultValue: "Stopped without a report", bundle: .module)
        }
    }

    /// `seconds` as the short localized duration ("5m 35s", "1h 2m", "48s").
    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: seconds.rounded(.down)) ?? ""
    }
}
