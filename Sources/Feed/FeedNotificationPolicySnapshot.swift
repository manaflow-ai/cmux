import Foundation

struct FeedNotificationPolicySnapshot: Sendable {
  let envelope: TerminalNotificationPolicyEnvelope
  let hooks: [CmuxResolvedNotificationHook]
  let globalConfigPath: String?
}
