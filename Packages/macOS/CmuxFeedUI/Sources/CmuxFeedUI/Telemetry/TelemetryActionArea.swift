public import SwiftUI

public import CMUXAgentLaunch

/// Renders the default (non-actionable) action area for a feed row.
///
/// For a ``FeedItemSnapshot`` whose payload is not one of the interactive kinds
/// (permission request, exit plan, question, stop), this view shows the
/// telemetry summary appropriate to the payload:
/// - ``WorkstreamPayload/todos(_:)`` renders the task list via ``TodoListBody``.
/// - A Claude assistant message renders inline markdown via
///   ``FeedMarkdownInlineText``.
/// - Anything else collapses to a monospaced one-to-three-line summary string.
///
/// The view is a pure value taking only the snapshot, so it never observes the
/// live store and re-renders only when the snapshot changes.
public struct TelemetryActionArea: View {
    let snapshot: FeedItemSnapshot

    /// Creates the telemetry action area for a feed row snapshot.
    /// - Parameter snapshot: The immutable feed-item projection to summarize.
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
