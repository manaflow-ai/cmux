public import Foundation

/// A pane's Sandboxed send (hq#3367), kept here rather than only in the page: a page reload (a web
/// update) loses the page's own state while the Cloud run goes on, so the reloaded page asks
/// (`sandbox.state`) and shows the same run, and a second `sandbox.run` is refused while one is out.
@MainActor
public final class AgentPaneSandboxRuns {
    /// The send in flight: its task and the work the App runs.
    private var running: (task: String, key: String, work: Task<Reply, Never>)?
    /// The last finished send: its task, its key (the page's attempt id) and the page's reply
    /// (`AgentPaneReply.sandbox`).
    private var last: (task: String, key: String, reply: [String: Any])?

    public init() {}

    public var isRunning: Bool { running != nil }

    /// Whether this pane's send, running or ended, is attempt `key`.
    public func holds(key: String) -> Bool { running?.key == key || last?.key == key }

    /// The attempt whose page may still show an answer older than its Run's end: its send answered
    /// without the receipt, and ``settle(key:snapshot:)`` put the receipt in its place afterwards.
    public private(set) var settledLate: String?
    /// A running send's Run that ended before the send answered: the send's reply, if it carries
    /// no receipt, becomes this one (``run(task:key:_:)``).
    private var endedEarly: (key: String, snapshot: [String: Any])?

    /// Attempt `key`'s Run ended. A send that answered without its receipt (a lost wait, the send's
    /// deadline) takes it for the page's next read; a send still running takes it when it answers.
    public func settle(key: String, snapshot: [String: Any]) {
        if running?.key == key { endedEarly = (key, snapshot); return }
        guard let last, last.key == key, last.reply["ok"] as? Bool != true else { return }
        self.last = (last.task, key, AgentPaneReply.sandbox(snapshot: snapshot))
        settledLate = key
    }

    /// A send that ended elsewhere, shown by this new pane as its own (``AgentPaneSeedSource/sandboxResult``):
    /// the page reads it with `sandbox.state`, and the tab's one send is spent. A pane that holds a send keeps it.
    func restore(_ result: AgentPaneSeed.SandboxResult?) {
        guard let result, running == nil, last == nil else { return }
        let card = result.card.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        last = (result.task, result.key, AgentPaneReply.sandbox(snapshot: card))
    }

    /// A send's reply as its task's result: main-actor bound, so it may cross the task's end.
    @MainActor final class Reply {
        let value: [String: Any]
        init(_ value: [String: Any]) { self.value = value }
    }

    /// The refusals that come before the server could create a Run (the page's `sandboxRetryable`),
    /// with the Run API's documented request refusals (``AgentPaneReply/runRequestRefusals``): after
    /// one of these the tab may send again. Any other code may hide a live Run.
    static let definiteRefusals: Set<String> = [
        "labs_off", "not_signed_in", "cloud_disabled", "unavailable_now", "unsupported", "transport.gesture_required",
        "run_sandbox_unavailable",
    ]

    /// Why a new `sandbox.run` is refused, or nil: one runs (`sandbox_busy`), or this tab's send
    /// already reached Cloud (`sandbox_spent`: a receipt, or an answer that may hide a live Run).
    /// One paid send per tab, so a reloaded page can't start a second for the same new chat.
    var refusal: String? {
        if running != nil { return "sandbox_busy" }
        guard let last, !Self.isDefiniteRefusal(last.reply) else { return nil }
        return "sandbox_spent"
    }

    /// A reply that refused the send before the server could create a Run.
    static func isDefiniteRefusal(_ reply: [String: Any]) -> Bool {
        let code = (reply["error"] as? [String: Any])?["code"] as? String
        guard reply["ok"] as? Bool == false, let code else { return false }
        return definiteRefusals.contains(code) || AgentPaneReply.runRequestRefusals.contains(code)
    }

    /// Runs `work` as this pane's one send and answers its reply.
    func run(task: String, key: String, _ work: @escaping @MainActor () async -> [String: Any]) async -> [String: Any] {
        // task-owner: the pane's one Sandboxed send; it ends when the App's runner answers (bounded there)
        let job = Task { @MainActor in Reply(await work()) }
        running = (task, key, job)
        var reply = await job.value.value
        running = nil
        if let ended = endedEarly, ended.key == key, reply["ok"] as? Bool != true { reply = AgentPaneReply.sandbox(snapshot: ended.snapshot) }
        endedEarly = nil
        last = (task, key, reply)
        return reply
    }

    /// `sandbox.state {wait}`: none, the running send (`{task, key, running: true}`), or the last
    /// one (`{task, key, reply}`). `key` is the page's id for that attempt. With `wait`, a running
    /// send is answered once it ends.
    func state(wait: Bool) async -> [String: Any] {
        if let running {
            guard wait else { return AgentPaneReply.success(["task": running.task, "key": running.key, "running": true]) }
            let reply = await running.work.value.value
            guard !Self.isDefiniteRefusal(reply) else { return AgentPaneReply.success() }
            return AgentPaneReply.success(["task": running.task, "key": running.key, "reply": reply])
        }
        // A refusal before any Run is no send to recover: nothing ran, and the page that sent it got
        // the answer (its prompt then lives in the composer's own kept draft). Only a run is reported.
        guard let last, !Self.isDefiniteRefusal(last.reply) else { return AgentPaneReply.success() }
        return AgentPaneReply.success(["task": last.task, "key": last.key, "reply": last.reply])
    }
}
