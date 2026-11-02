public import CmuxNextDaemon
import CmuxNextCompat
import Observation

/// The Cloud approval holds (G8, cx-wb5.65) the person has answered, as their feed shows them. The
/// backend posts each hold as an approve item in the person's `FeedDO`; the item closes in the same
/// commit that takes the person's answer on any device (the phone, the dashboard, another Mac), and
/// the feed owner pushes that event to the Mac's mirror at once. The app records each closed hold
/// here, so a create flow knows the hold was answered without polling for it (cmux#32354).
@MainActor @Observable
public final class CloudApprovalHolds {
    /// The requests whose approve item is closed. A closed item never opens again.
    private var answered: Set<String> = []

    public init() {}

    /// The feed owner's closed approve items, by the hold request each carries.
    public func recordAnswered(_ requests: some Sequence<String>) {
        let new = Set(requests).subtracting(answered)
        if !new.isEmpty { answered.formUnion(new) }
    }

    public func isAnswered(_ request: String) -> Bool { answered.contains(request) }

    /// True once `request` is answered; false when the waiting task is cancelled first.
    public func answer(of request: String) async -> Bool {
        for await done in ObservationStream({ self.isAnswered(request) }) where done { return true }
        return false
    }
}

/// The "Create a Cloud machine?" sheet for one held op, ended by the first answer: the person's
/// click; the hold answered elsewhere, as the feed pushes it (``CloudApprovalHolds``); or, when the
/// push is missing, the same-key call at `watchPause`'s pace that finds the op's answer or a denial.
@MainActor
public struct CloudApprovalSheet {
    public enum Answer: Sendable, Equatable { case no, yes, answeredElsewhere }

    public var run: CloudAppOp
    public var holds: CloudApprovalHolds?
    public var watchPause: (@MainActor (_ attempt: Int) async throws -> Void)?

    public init(run: @escaping CloudAppOp, holds: CloudApprovalHolds?, watchPause: (@MainActor (_ attempt: Int) async throws -> Void)?) {
        self.run = run
        self.holds = holds
        self.watchPause = watchPause
    }

    /// The answer to hold `request` of `op` (sent with `key`). `ask` shows the sheet; it is cancelled,
    /// which closes it, when the hold is answered elsewhere first. A click that comes together with
    /// the push is read against the hold's state: answered elsewhere, so the hold is not answered again.
    public func answer(request: String, op: String, args: JSONValue, key: String, ask: @escaping @MainActor () async -> Bool) async -> Answer {
        if holds?.isAnswered(request) == true { return .answeredElsewhere }
        var watches: [@MainActor () async -> Bool] = []
        if let holds { watches.append { await holds.answer(of: request) } }
        if let watchPause { watches.append { [self] in await watch(request, op: op, args: args, key: key, pause: watchPause) } }
        guard !watches.isEmpty else { return await ask() ? .yes : .no }
        @MainActor final class Seen { var answered = false }
        let elsewhere = Seen()
        let yes = await CloudWait.firstAnswer(ask: ask) {
            // The push or the watch, whichever finds the answer first (each alone when the other is missing).
            elsewhere.answered = watches.count == 1 ? await watches[0]() : await CloudWait.firstAnswer(ask: watches[0], elsewhere: watches[1])
            return elsewhere.answered
        }
        return elsewhere.answered || holds?.isAnswered(request) == true ? .answeredElsewhere : yes ? .yes : .no
    }

    /// The same-key call after each `pause`: answered when it returns the op's answer or a denial or
    /// expiry; nil (ask again) while this request is pending; false for anything else.
    private func watch(_ request: String, op: String, args: JSONValue, key: String, pause: @MainActor (_ attempt: Int) async throws -> Void) async -> Bool {
        await CloudWait.untilAnswered(pause: pause) { [run] in
            do { _ = try await run(op, args, key, .user) } catch let failure as CloudAppOpFailure where failure.code == CloudAppOpFailure.approvalPending {
                return failure.approvalRequest == request ? nil : false
            } catch { return Self.isDefinitiveAnswer(error) }
            return true
        }
    }

    /// A denied or expired hold was answered too; anything else leaves the answer to the sheet.
    static func isDefinitiveAnswer(_ error: any Error) -> Bool {
        (error as? CloudAppOpFailure).map { failure in ["approval_denied", "approval.denied", "approval_expired", "approval.expired"].contains { failure.code.hasSuffix($0) } } ?? false
    }
}
