import Foundation

struct FeedNotificationPolicySnapshot: Sendable {
  let envelope: TerminalNotificationPolicyEnvelope
  let globalConfigPath: String?
  let hookSearchDirectory: String?
}
