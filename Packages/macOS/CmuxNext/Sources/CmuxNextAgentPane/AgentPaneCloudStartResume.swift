public import CmuxNextSettings
public import Foundation

/// A Cloud start this pane's page sent, kept by the host for whichever page shows the pane next.
///
/// The page owns a start's card (webviews `cloudStartProgress.ts`): its prompt, its steps and its end all live in the
/// page's memory, and the start's answer goes back on the page's own request. A page built again while its start runs
/// (the health check's reload of a page that stopped answering clicks, a hibernated page shown again) had none of
/// that: it drew an empty New Tab, the prompt gone, and the start's answer, a failure included, went to the page that
/// was no longer there. The host keeps this record from the start's run to its end, hands it to the next page in its
/// handshake (``AgentPaneHandshake/cloudStartResume``), and tells that page the end as a `cloudStartProgress` push
/// (``AgentPaneCloudStart/ended(_:start:to:)``), so the person sees the start, then the chat or its failure and Retry.
public nonisolated struct AgentPaneCloudStartResume: Codable, Sendable, Equatable {
    /// How the start ended, as the page's `CloudStartAnswer` reads it (webviews cloudRun.ts).
    public nonisolated struct Ended: Codable, Sendable, Equatable {
        public var ok: Bool
        public var code: String?
        public var message: String?
        public var retryable: Bool?

        public init(ok: Bool, code: String? = nil, message: String? = nil, retryable: Bool? = nil) {
            (self.ok, self.code, self.message, self.retryable) = (ok, code, message, retryable)
        }

        /// The end of a start from its reply (``AgentPaneReply``): `{ok}` or `{ok: false, error: {code, userMessage, retryable}}`.
        public init(reply: [String: Any]) {
            let error = reply["error"] as? [String: Any]
            self.init(ok: reply["ok"] as? Bool == true, code: error?["code"] as? String,
                      message: error?["userMessage"] as? String ?? error?["message"] as? String,
                      retryable: error?["retryable"] as? Bool)
        }

        /// The push's `ended` field.
        public var json: JSONValue {
            var fields: [String: JSONValue] = ["ok": .bool(ok)]
            if let code { fields["code"] = .string(code) }
            if let message { fields["message"] = .string(message) }
            if let retryable { fields["retryable"] = .bool(retryable) }
            return .object(fields)
        }
    }

    public var key: String
    /// The person's prompt, shown again as the start's message (never logged).
    public var task: String
    public var cwd: String?
    public var home: Bool?
    public var harness: String?
    public var model: String?
    /// The start's progress pushes so far, their fields merged (the page's `cloudStartProgress` push).
    public var progress: [String: JSONValue]?
    /// Set once the start ended without opening its chat; nil while it runs.
    public var ended: Ended?
    /// When the start began (ms since 1970): a record this old is no page's any more.
    public var startedAtMs: Double

    /// How long a start's record is handed to a page built again: a start runs minutes, never hours.
    public static let keptForMs: Double = 30 * 60 * 1000

    public init(_ start: AgentPaneCloudStart, now: Date = Date()) {
        (key, task, cwd, harness, model) = (start.key, start.task, start.cwd, start.harness, start.model)
        home = start.home ? true : nil
        startedAtMs = (now.timeIntervalSince1970 * 1000).rounded()
    }

    /// Takes in one progress push of this start (`key` matches); any other push changes nothing.
    public mutating func absorb(_ push: JSONValue) {
        guard ended == nil, let fields = push.objectValue, fields["key"]?.stringValue == key else { return }
        var merged = progress ?? [:]
        merged.merge(fields) { $1 }
        progress = merged
    }

    /// Whether a page built at `now` is still shown this record.
    public func current(now: Date = Date()) -> Bool {
        now.timeIntervalSince1970 * 1000 - startedAtMs < Self.keptForMs
    }
}

extension AgentPaneModel {
    /// A start this pane's page sent began to run: kept until it ends (``endCloudStartResume(key:reply:)``).
    @MainActor public func beginCloudStartResume(_ start: AgentPaneCloudStart) {
        cloudStartResume = AgentPaneCloudStartResume(start)
    }

    /// A progress push of the start that runs (``AgentPaneCloudStart/progress(_:to:)``).
    @MainActor func noteCloudStartProgress(_ push: JSONValue) {
        cloudStartResume?.absorb(push)
    }

    /// Start `key` ended with `reply`: a chat that opened (or that runs on this Mac instead) is no start any more; a
    /// failure is kept for a page built again before the person saw it. Returns the end, for the push.
    @MainActor @discardableResult
    public func endCloudStartResume(key: String, reply: [String: Any]) -> AgentPaneCloudStartResume.Ended {
        let ended = AgentPaneCloudStartResume.Ended(reply: reply)
        guard cloudStartResume?.key == key else { return ended }
        if ended.ok { cloudStartResume = nil } else { cloudStartResume?.ended = ended }
        return ended
    }

    /// The record a page's handshake gets: none once a new start replaced it, its chat opened, or it is old. The page
    /// shows it only where it shows a start at all (no chat, or the empty chat the start replaces).
    @MainActor func cloudStartResumeForPage(now: Date = Date()) -> AgentPaneCloudStartResume? {
        guard let record = cloudStartResume else { return nil }
        guard record.current(now: now) else {
            cloudStartResume = nil
            return nil
        }
        return record
    }
}

extension AgentPaneCloudStart {
    /// Runs this start (`run`, the App's start) kept on `view`'s pane from its run to its end: a page built again
    /// meanwhile (a health reload, a hibernated page shown again) shows it, and hears its end as a push.
    @MainActor public func resumable(on view: AgentPaneView, _ run: @MainActor () async -> [String: Any]) async -> [String: Any] {
        view.model.beginCloudStartResume(self)
        let reply = await run()
        Self.ended(view.model.endCloudStartResume(key: key, reply: reply), start: key, to: view)
        return reply
    }

    /// Tells the page start `key` ended (`cloudStartProgress {key, ended}`). The page that sent the start reads its own
    /// answer and ignores this; a page built again since (which has no answer coming) ends the start's card with it.
    @MainActor public static func ended(_ ended: AgentPaneCloudStartResume.Ended, start key: String, to view: AgentPaneView) {
        let push = JSONValue.object(["key": .string(key), "ended": ended.json])
        view.deliver([AgentPageEvent(kind: "cloudStartProgress", value: push)],
                     scripts: ["window.cmuxAcpmuxBridge?.cloudStartProgress?.(\(push.compactText));"])
    }
}
