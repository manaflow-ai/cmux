public import CmuxNextActions
public import CmuxNextCloud
public import Foundation

/// Cloud machine changes an agent or a script asked for (`cmux vm resize`, `fork`, `snapshot-machine`, `restore-machine`,
/// `promote-template`), which wait for the person's Allow in the ``CloudChangeRequest`` dialog. The dialog stays. A run
/// answers its caller at once that it waits (`pending`, `waiting_for: person`, the dialog's `dialog_id`, `ask_again_joins`)
/// instead of 30 s of silence; the same ask again joins that run (``CloudStartRuns``), never a second change or dialog,
/// and gets its end: the change's own answer, or its failure (Don't Allow included), so no caller reads a declined change
/// as done. The App keeps one per Cloud service.
@MainActor
public final class CloudMachineChanges {
    public typealias Fields = [String: ActionResultValue]
    /// Shows the person's dialog when it runs, telling `shown` its id, and answers their yes.
    public typealias Ask = @MainActor (_ shown: @escaping @MainActor (Int) -> Void) -> @MainActor () async -> Bool

    let runs = CloudStartRuns<Fields, Bool>()
    /// The waiting answer of each run whose dialog is open, for a caller who joins it then.
    var asks: [CloudStartRunKey: Fields] = [:]

    public init() {}

    // A main-actor class: its isolated deinit crashes the Release optimizer (#23050).
    nonisolated deinit {}

    /// What makes two asks of a change the same run: the action, its machine, its arguments, the asking agent chat
    /// and the account.
    public static func key(action: String, machine: String, arguments: [String: ActionValue], caller: String?,
                           account: [String?]) -> CloudStartRunKey {
        let asked = arguments.keys.sorted().map { "\($0)=\(String(describing: arguments[$0]))" }.joined(separator: "&")
        return CloudStartRunKey(machine: "change:" + machine, agent: action, cwd: asked, caller: caller, account: account)
    }

    /// The end of `key`'s run, or its waiting answer: `pending` plus who it waits for once the dialog shows, at once
    /// for the caller that started it, else after `wait`. `work` gets the person's yes from `ask` to pass on.
    public func run(_ key: CloudStartRunKey, within wait: Duration, pending: Fields, ask: Ask,
                    _ work: @escaping @MainActor (_ allow: @escaping @MainActor () async -> Bool) async throws -> Fields) async throws -> Fields {
        let waiting = pending.merging(["pending": .bool(true), "ask_again_joins": .bool(true)]) { field, _ in field }
        let asked = ask { [weak self] dialog in
            let asking = waiting.merging(["waiting_for": .string("person"), "dialog_id": .string(String(dialog)),
                                          "dialog": .string(CloudChangeRequest.identifier)]) { field, _ in field }
            self?.asks[key] = asking
            self?.runs.asking(key, asking)
        }
        // The dialog answered: a caller who joins now waits for the change, not the person.
        let allow: @MainActor () async -> Bool = { [weak self] in
            let allowed = await asked()
            self?.asks[key] = nil
            return allowed
        }
        return try await runs.answer(key, within: wait, pending: asks[key] ?? waiting, forgotten: CancellationError(), early: true) { [weak self] in
            defer { self?.asks[key] = nil }
            return try await work(allow)
        }
    }
}
