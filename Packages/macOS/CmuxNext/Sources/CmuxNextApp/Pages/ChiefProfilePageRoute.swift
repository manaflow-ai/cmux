import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups

/// `cmux.chief.profile.*` of the home-channels page -> this build's Chief owner, with the person's
/// gesture confirmed on the app's trusted connection (ChiefProfilePageRelay). Thin: route only.
@MainActor
final class ChiefProfilePageRoute: PageProvider {
    nonisolated static let prefix = "cmux.chief.profile."
    private let relay: ChiefProfilePageRelay

    /// The route of `owner`'s relay, which the page host keeps (one per owner, shared by Home and
    /// Settings): its page stream closes ``PageRelayIdleClose/delay`` after the last call.
    init(owner: ChiefConversationOwner, channels: PageRelayChannels, deadlines: MainDeadlineScheduler) {
        relay = channels.channel(for: PageRelayChannels.Key(service: ObjectIdentifier(owner), page: ChiefProfilePageRelay.page)) {
            // A close tears down what nobody uses: background class, behind input and visible work.
            ChiefProfilePageRelay(owner: owner, idle: MainDeadline(owner: "ChiefProfilePageRelay.idleClose", workClass: .background,
                                                                   scheduler: deadlines))
        }
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard op.hasPrefix(Self.prefix) else { throw PageError.unknownOp(op) }
        var members = params.objectValue ?? [:]
        let key = DaemonPageRelay.idempotencyKey(members.removeValue(forKey: "idempotency_key")?.stringValue, context: context)
        do {
            let result = try await relay.send(operation: String(op.dropFirst("cmux.".count)), params: try DaemonPageRelay.daemonParams(members),
                                              idempotencyKey: key, gestureEvent: context.userGesture ? context.gestureEvent : nil)
            return try DaemonPageRelay.pageValue(result)
        } catch let error as DaemonError {
            throw DaemonPageRelay.pageError(error)
        }
    }
}
