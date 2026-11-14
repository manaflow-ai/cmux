public import CmuxNextActions
import Foundation

/// How far one Cloud run a CLI, MCP or script caller waits on got. A run that outlasts its wait answers
/// `pending` and keeps going; while the person is asked to allow it (``CloudChangeRequest``'s sheet, a
/// create's sidebar card), that answer says so (`awaiting: "allow"` and a sentence), and a failure after
/// it, which no caller hears any more, goes to the person (``lateFailure(_:label:)``). Before, `cmux vm fork` from an agent waited on that
/// sheet, answered a bare `pending` (`ran true`, `created []`), and ended unseen when the sheet went:
/// no machine and no word of why (2026-11-11).
@MainActor public final class CloudRunProgress {
    /// The progress of the run this task belongs to (none: nobody reads it).
    @TaskLocal public static var current: CloudRunProgress?
    /// The title of what the person is asked to allow, while it is asked.
    public private(set) var awaitingAllow: String?
    /// The last action this run asked the person about.
    public private(set) var asked: String?
    /// The caller has the `pending` answer: what happens next, only the person hears.
    public private(set) var answeredPending = false
    /// The run's outcome shows on its own (a create's progress page): a late failure needs no notice.
    public private(set) var outcomeShown = false

    public init() {}

    /// Runs `body` with this progress current.
    public func running<T>(_ body: @MainActor () async throws -> T) async throws -> T {
        // concurrency-allow: the async overload of withValue binds inside the calling task (always current in an async
        // function), never in the thread's fallback storage that cx-bpcj is about (the shared-package rule exempts it too).
        try await Self.$current.withValue(self) { try await body() }
    }

    /// `ask`'s answer, with the current run (if any) marked as asking the person about `title` meanwhile.
    public static func asking(_ title: String, _ ask: @MainActor () async -> Bool) async -> Bool {
        guard let current else { return await ask() }
        return await current.asking(title, ask)
    }

    /// From now on the run's outcome shows on its own: ``lateFailure(_:label:)`` answers nil.
    public func showsItsOutcome() { outcomeShown = true }

    /// `ask`'s answer, with this run marked as asking the person about `title` meanwhile.
    public func asking(_ title: String, _ ask: @MainActor () async -> Bool) async -> Bool {
        asked = title
        awaitingAllow = title
        defer { awaitingAllow = nil }
        return await ask()
    }

    /// `fields` as the run's `pending` answer: `pending: true`, plus `awaiting: "allow"` and its `text` while the
    /// Allow sheet is up. From now on a failure is the person's to hear (``lateFailure(_:label:)``).
    public func pendingAnswer(_ fields: [String: ActionResultValue]) -> [String: ActionResultValue] {
        answeredPending = true
        var answer = fields
        answer["pending"] = answer["pending"] ?? .bool(true)
        if let awaitingAllow {
            answer["awaiting"] = .string("allow")
            answer["text"] = .string(Self.awaitingAllowText(awaitingAllow))
        }
        return answer
    }

    /// The notice of a failure (`reason`) that came after the `pending` answer, naming the asked action (else
    /// `label`); nil while the caller still waits, since the caller hears the failure itself.
    public func lateFailure(_ reason: String, label: String) -> ActionWorkFailure? {
        guard answeredPending, !outcomeShown else { return nil }
        return ActionWorkFailure(refusal: .unavailable, reason: Self.lateFailureText(asked ?? label, reason))
    }

    /// "Waiting for your answer in the cmux window: “Fork Cloud Machine”. Nothing changes until you answer."
    public nonisolated static func awaitingAllowText(_ title: String) -> String {
        String(format: String(localized: "cloud.run.awaitingAllow", defaultValue: "Waiting for your answer in the cmux window: “%@”. Nothing changes until you answer.",
                              table: "Cloud", bundle: .module), title)
    }

    /// "“Fork Cloud Machine” did not finish: REASON"
    public nonisolated static func lateFailureText(_ title: String, _ reason: String) -> String {
        String(format: String(localized: "cloud.run.lateFailure", defaultValue: "“%1$@” did not finish: %2$@", table: "Cloud", bundle: .module), title, reason)
    }
}
