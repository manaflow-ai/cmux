import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextDesign
import Foundation

/// Decode only authenticated tell tools (with the prompt's `_meta.cmux.sender`) and the Chief producer's report-note namespace.
nonisolated enum HomeAgentRunMapping {
    static func run(_ run: ConversationRunSummary, conversation: String, steps: [ConversationRunRows.Step],
                    author: (String) -> ParticipantID) -> HomeAgentRun {
        HomeAgentRun(conversation: ConversationID(conversation), id: run.id, author: author(run.author),
                     turn: run.turn.map { IdempotencyKey($0) }, answers: (run.answers ?? []).map { MessageID($0) },
                     threadRoot: run.threadRoot.map { MessageID($0) }, revision: run.rev ?? 0, messages: steps.flatMap { step -> [HomeAgentRun.Message] in
            let date = Date(timeIntervalSince1970: (step.at ?? step.tool?.startedAt ?? run.startedAt ?? 0) / 1000)
            if let spawned = spawned(step) {
                // A spawn is the Chief's first message to each agent it started: its task (with the `Title:` line
                // the agent's pill and chat are named by; user 2026-11-04, msg 21664).
                return spawned.map { peer, task in
                    HomeAgentRun.Message(id: "\(step.id):\(peer)", sequence: step.seq ?? 0, revision: step.rev ?? 0, peer: peer,
                                         outgoing: true, text: task, date: date, sender: step.tool?.input?.sender)
                }
            }
            let peer: String, text: String, outgoing: Bool
            var sender: String?
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
                sender = tool.input?.sender
            } else if step.kind == "note", step.id.hasPrefix("report:"), let body = step.text,
                      body.hasPrefix("["), let end = body.range(of: "] ") {
                peer = String(body.dropFirst().prefix(upTo: end.lowerBound))
                text = String(body[end.upperBound...])
                outgoing = false
            } else {
                return []
            }
            return [HomeAgentRun.Message(id: step.id, sequence: step.seq ?? 0, revision: step.rev ?? 0,
                                         peer: peer, outgoing: outgoing, text: text, date: date, sender: sender)]
        })
    }

    /// A finished `spawn` step's agents and their tasks: the answer's `Started a1, a2 …` line gives the ids in task
    /// order (optchat-chief subagents.rs). Nil for any other step, a spawn with no answer yet, or an answer that
    /// names a different count of agents than it had tasks (a wrong name is worse than none).
    private static func spawned(_ step: ConversationRunRows.Step) -> [(peer: String, task: String)]? {
        guard step.kind == "tool", let tool = step.tool, let tasks = tool.input?.tasks, !tasks.isEmpty,
              ["spawn", "optchat.spawn", "mcp__optchat__spawn"].contains(tool.name) || tool.input?.isSpawnEnvelope == true,
              let output = tool.output, let started = output.range(of: "Started ") else { return nil }
        var ids: [String] = []
        for word in output[started.upperBound...].split(separator: " ") {
            let id = word.hasSuffix(",") ? word.dropLast() : word
            guard id.count > 1, id.first == "a", id.dropFirst().allSatisfy(\.isASCIIDigitCharacter) else { break }
            ids.append(String(id))
            guard word.hasSuffix(",") else { break }
        }
        guard ids.count == tasks.count else { return nil }
        return Array(zip(ids, tasks))
    }
}

private extension Character {
    /// `0`-`9` only (agent ids are `a` and ASCII digits).
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}
