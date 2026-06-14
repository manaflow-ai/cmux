import Foundation

protocol AgentNeedsInputSessionStoring {
    func recentlyEmittedNotification(
        sessionId: String,
        fingerprint: String,
        within interval: TimeInterval
    ) throws -> Bool

    func markNotificationEmitted(
        sessionId: String,
        fingerprint: String,
        marksAskUserQuestion: Bool
    ) throws
}
