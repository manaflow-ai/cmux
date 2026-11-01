import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextDesign
import Foundation

/// Decode only authenticated tell tools and the Chief producer's report-note namespace.
nonisolated enum HomeAgentRunMapping {
    static func run(_ run: ConversationRunSummary, conversation: String, steps: [ConversationRunRows.Step],
                    author: (String) -> ParticipantID) -> HomeAgentRun {
        HomeAgentRun(conversation: ConversationID(conversation), id: run.id, author: author(run.author),
                     turn: run.turn.map { IdempotencyKey($0) }, answers: (run.answers ?? []).map { MessageID($0) },
                     threadRoot: run.threadRoot.map { MessageID($0) }, revision: run.rev ?? 0, messages: steps.compactMap { step in
            let peer: String, text: String, outgoing: Bool
            if step.kind == "tool", let tool = step.tool,
               (["tell", "optchat.tell", "mcp__optchat__tell"].contains(tool.name) || tool.input?.isTellEnvelope == true),
               let id = tool.input?.id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let message = tool.input?.message {
                var body = message
                let reason = tool.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // A successful tool invocation can refuse delivery (cancelled agent, deleted VM).
                let refused = reason == "outcome: refused" || reason.hasPrefix("outcome: refused.")
                if (step.status == "failed" || tool.status == "failed" || refused),
                   let failureLabel = StatusIndicatorState.error.shortLabel {
                    body += reason.isEmpty ? "\n[\(failureLabel)]" : "\n[\(failureLabel): \(reason)]"
                }
                (peer, text, outgoing) = (id, body, true)
            } else if step.kind == "note", step.id.hasPrefix("report:"), let body = step.text,
                      body.hasPrefix("["), let end = body.range(of: "] ") {
                peer = String(body.dropFirst().prefix(upTo: end.lowerBound))
                text = String(body[end.upperBound...])
                outgoing = false
            } else {
                return nil
            }
            return HomeAgentRun.Message(id: step.id, sequence: step.seq ?? 0, revision: step.rev ?? 0,
                                        peer: peer, outgoing: outgoing, text: text,
                                        date: Date(timeIntervalSince1970: (step.at ?? step.tool?.startedAt ?? run.startedAt ?? 0) / 1000))
        })
    }
}
