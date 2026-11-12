public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// The diff tab's review brief: `cmux.diff.brief {repoRoot}` → acpmux's answer for the chat that
/// opened the tab (`{sessionId, seq, brief}`, acpmux `review_brief.rs`), for the tab's own
/// repository only. The page draws it (webviews/src/review-brief); this only relays.
extension DiffPageProvider {
    static let briefOp = "cmux.diff.brief"

    /// Answers `cmux.diff.brief`; nil for any other op.
    func briefCall(_ op: String, params: JSONValue) async throws -> JSONValue? {
        guard op == Self.briefOp else { return nil }
        guard let chat = chat() else { throw PageError(code: "cmux.diff.no_chat", message: "No chat owns this diff") }
        let root = try await gitRepository()
        guard params["repoRoot"]?.stringValue == root else {
            throw PageError(code: "notAllowed", message: "Not this tab's repository")
        }
        let data: Data?
        do {
            data = try await chat.brief(root)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PageError(code: "cmux.diff.brief_unavailable", message: "The chat's brief could not be read", retryable: true)
        }
        guard let data, let answer = try? JSONValue.parse(data) else {
            throw PageError(code: "cmux.diff.brief_unavailable", message: "The chat's brief could not be read", retryable: true)
        }
        return answer
    }

    /// `config` listing `cmux.diff.brief` and `payload.reviewBrief` when a chat owns the tab, so
    /// the page keeps the brief's row from its first frame.
    func withBrief(_ config: JSONValue) -> JSONValue {
        guard chat() != nil, case .object(var members) = config, members["pick"] == nil,
              case .object(var payload)? = members["payload"] else { return config }
        members["ops"] = .array((members["ops"]?.arrayValue ?? []) + [.string(Self.briefOp)])
        payload["reviewBrief"] = true
        members["payload"] = .object(payload)
        return .object(members)
    }
}
