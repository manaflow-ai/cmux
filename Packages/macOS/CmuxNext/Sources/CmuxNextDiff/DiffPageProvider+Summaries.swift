public import CmuxNextAgentPane
public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// Who writes a diff tab's hunk sentences (Plain English, webviews/src/diff-viewer/hunkSummaries.ts):
/// this Mac's acpmux (`_acpmux/hunk_summary`), on the harness of the chat that opened the tab
/// when it has one, else the default. acpmux keeps each sentence by the hunk's content hash.
public struct DiffHunkSummarizer: Sendable {
    /// `(path, patch)` → `{text, key, cached}` as JSON.
    let summarize: @Sendable (String, String) async throws -> Data
    /// `{ready, harness}` as JSON, running nothing; throws why no harness could answer.
    let check: @Sendable () async throws -> Data

    public init(summarize: @escaping @Sendable (String, String) async throws -> Data,
                check: @escaping @Sendable () async throws -> Data) {
        self.summarize = summarize
        self.check = check
    }

    /// Through `environment`'s acpmux, on chat `session`'s harness when given. Nil without acpmux.
    public static func local(session: String?, environment: AcpmuxEnvironment?) -> DiffHunkSummarizer? {
        guard let environment else { return nil }
        var chat: [String: any Sendable] = [:]
        if let session, !session.isEmpty { chat["sessionId"] = session }
        let base = chat
        return DiffHunkSummarizer(summarize: { path, patch in
            var params = base
            params["path"] = path
            params["patch"] = patch
            return try await environment.harness(.hunkSummary, params: params)
        }, check: {
            var params = base
            params["check"] = true
            return try await environment.harness(.hunkSummary, params: params)
        })
    }
}

/// `cmux.diff.summary {path, patch}` → `{text, key, cached}` and `cmux.diff.summaryCheck {}` →
/// `{ready: true, harness}` or `{ready: false, reason}` (an acpmux `data.reason`, or
/// `cmux.diff.no_acpmux`). This only relays; the page asks only for hunks on screen.
extension DiffPageProvider {
    static let summaryOp = "cmux.diff.summary"
    static let summaryCheckOp = "cmux.diff.summaryCheck"
    /// The longest patch relayed, as acpmux's own limit.
    static let maximumSummaryPatchBytes = 256 * 1024

    /// Answers the two summary ops; nil for any other op.
    func summariesCall(_ op: String, params: JSONValue) async throws -> JSONValue? {
        guard op == Self.summaryOp || op == Self.summaryCheckOp else { return nil }
        guard let summarizer = summarizer() else {
            if op == Self.summaryCheckOp { return ["ready": false, "reason": "cmux.diff.no_acpmux"] }
            throw PageError(code: "cmux.diff.no_acpmux", message: "No agent can write summaries here")
        }
        if op == Self.summaryCheckOp {
            do {
                return try JSONValue.parse(try await summarizer.check())
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AcpmuxRPCError {
                return ["ready": false, "reason": .string(error.name ?? "cmux.diff.summary_unavailable")]
            } catch {
                return ["ready": false, "reason": "cmux.diff.summary_unavailable"]
            }
        }
        guard let path = params["path"]?.stringValue, let patch = params["patch"]?.stringValue,
              !patch.isEmpty, patch.utf8.count <= Self.maximumSummaryPatchBytes else {
            throw PageError.invalidParams("path and patch are required")
        }
        do {
            return try JSONValue.parse(try await summarizer.summarize(path, patch))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let reason = (error as? AcpmuxRPCError)?.name ?? "cmux.diff.summary_unavailable"
            throw PageError(code: reason, message: "The summary could not be written", retryable: true)
        }
    }

    /// The tab's chat (Send to agent, the brief) and this Mac's acpmux, which writes the hunk
    /// sentences on that chat's harness when it has one.
    public func connect(chat: @escaping () -> DiffTabChat?, acpmux: @escaping () -> AcpmuxEnvironment?) {
        self.chat = chat
        summarizer = { DiffHunkSummarizer.local(session: chat()?.session, environment: acpmux()) }
    }

    /// `config` listing the summary ops when this tab has a summarizer: the page's Plain English
    /// toggle asks `summaryCheck` before it offers itself.
    func withSummaries(_ config: JSONValue) -> JSONValue {
        guard !chatPatch, summarizer() != nil, case .object(var members) = config, members["pick"] == nil else {
            return config
        }
        members["ops"] = .array((members["ops"]?.arrayValue ?? []) + [.string(Self.summaryOp), .string(Self.summaryCheckOp)])
        return .object(members)
    }
}
