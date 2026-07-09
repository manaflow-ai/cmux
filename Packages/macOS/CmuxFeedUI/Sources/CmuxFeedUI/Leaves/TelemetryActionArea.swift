import Foundation
public import CMUXAgentLaunch
public import SwiftUI

/// Compact secondary line shown under a feed item's primary content. Renders a
/// task list for `.todos`, inline markdown for Claude assistant messages, and a
/// one-line monospaced telemetry summary for tool calls and lifecycle events.
public struct TelemetryActionArea: View {
    let snapshot: FeedItemSnapshot

    public init(snapshot: FeedItemSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        if case .todos(let todos) = snapshot.payload {
            TodoListBody(todos: todos)
        } else if case .assistantMessage(let text) = snapshot.payload,
                  snapshot.source == .claude {
            FeedMarkdownInlineText(
                text: text,
                fontSize: 11,
                foregroundColor: .secondary.opacity(0.85)
            )
            .lineLimit(3)
            .truncationMode(.tail)
        } else if !summary.isEmpty {
            Text(summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(3)
                .truncationMode(.tail)
        }
    }

    private var summary: String {
        switch snapshot.payload {
        case .toolUse(let name, let json):
            return "\(name) \(json)"
        case .toolResult(let name, let json, let err):
            let status = err
                ? String(localized: "feed.telemetry.error", defaultValue: "error", bundle: .main)
                : String(localized: "feed.telemetry.ok", defaultValue: "ok", bundle: .main)
            return "\(name) \(status) \(json)"
        case .userPrompt(let text), .assistantMessage(let text):
            return text
        case .sessionStart:
            return String(localized: "feed.telemetry.sessionStart", defaultValue: "session start", bundle: .main)
        case .sessionEnd:
            return String(localized: "feed.telemetry.sessionEnd", defaultValue: "session end", bundle: .main)
        case .stop(let reason):
            let label = String(localized: "feed.telemetry.stop", defaultValue: "stop", bundle: .main)
            guard let reason, !reason.isEmpty else { return label }
            return "\(label) \(reason)"
        default:
            return ""
        }
    }
}
