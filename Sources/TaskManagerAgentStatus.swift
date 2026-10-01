import Foundation
import SwiftUI

/// What the Task Manager shows about one coding agent's lifecycle: the same
/// per-terminal lifecycle state the sidebar and agent hibernation read, plus
/// how long the agent has been in a non-running state.
struct CmuxTaskManagerAgentStatus: Equatable {
    enum State: String, Equatable {
        case running
        case needsInput
        case idle
        case hibernated
        case unknown

        /// Maps the `agent_panels` wire value (an
        /// `AgentHibernationLifecycleState` raw value or `hibernated`).
        /// The sidebar status text is the fallback when no lifecycle key is
        /// set, e.g. "Needs input" from a hook that only wrote status.
        init(wireValue: String?, statusText: String?) {
            if let wireValue, wireValue == State.hibernated.rawValue {
                self = .hibernated
                return
            }
            let lifecycle = wireValue.flatMap(AgentHibernationLifecycleState.parseCLIValue)
            if let lifecycle, lifecycle != .unknown {
                self.init(lifecycle)
                return
            }
            let normalizedText = statusText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "-")
            if let normalizedText,
               let parsed = AgentHibernationLifecycleState.parseCLIValue(normalizedText) {
                self.init(parsed)
                return
            }
            self = .unknown
        }

        init(_ lifecycle: AgentHibernationLifecycleState) {
            switch lifecycle {
            case .running: self = .running
            case .backgroundWorkPending: self = .running
            case .needsInput: self = .needsInput
            case .idle: self = .idle
            case .unknown: self = .unknown
            }
        }

        var label: String {
            switch self {
            case .running:
                String(localized: "taskManager.agentStatus.running", defaultValue: "Running")
            case .needsInput:
                String(localized: "taskManager.agentStatus.needsInput", defaultValue: "Needs input")
            case .idle:
                String(localized: "taskManager.agentStatus.idle", defaultValue: "Idle")
            case .hibernated:
                String(localized: "taskManager.agentStatus.hibernated", defaultValue: "Hibernated")
            case .unknown:
                String(localized: "taskManager.agentStatus.unknown", defaultValue: "Unknown")
            }
        }

        var tint: Color {
            switch self {
            case .running: .green
            case .needsInput: .orange
            case .idle, .unknown: .secondary
            case .hibernated: .purple
            }
        }

        /// A running agent is busy by definition; every other state reports
        /// how long it has been waiting.
        var showsElapsedTime: Bool {
            self != .running && self != .unknown
        }
    }

    let state: State
    /// Whole minutes since the agent entered `state`, when known.
    let elapsedMinutes: Int?

    init(state: State, since: Date?, now: Date) {
        self.state = state
        if state.showsElapsedTime, let since {
            self.elapsedMinutes = max(0, Int(now.timeIntervalSince(since) / 60))
        } else {
            self.elapsedMinutes = nil
        }
    }

    /// "12m", "1h 5m" beside the state label. Minute granularity keeps the
    /// row payload stable between 3 s refreshes, so `.equatable()` rows only
    /// re-render when the visible text changes.
    var elapsedText: String? {
        elapsedMinutes.map(Self.elapsedText(minutes:))
    }

    /// System-localized abbreviated duration ("12m", "1h 5m", "2d 3h").
    static func elapsedText(minutes: Int) -> String {
        let formatter = minutes < 1 ? minuteFormatter : elapsedFormatter
        return formatter.string(from: TimeInterval(max(0, minutes) * 60)) ?? ""
    }

    private static let minuteFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()

    private static let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()
}
