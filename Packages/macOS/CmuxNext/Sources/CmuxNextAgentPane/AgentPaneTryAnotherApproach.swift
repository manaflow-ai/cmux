import Foundation

/// The Cloud chat's latest-turn-only machine + transcript fork. The app owns the operation so the
/// page cannot accidentally mutate or select the parent while a child is being prepared.
public nonisolated struct AgentPaneTryAnotherApproach: Equatable, Sendable {
    public let throughSeq: Int

    public init?(params: [String: Any]?) {
        guard let params, Set(params.keys) == ["throughSeq"] else { return nil }
        guard let value = (params?["throughSeq"] as? NSNumber)?.intValue, value > 0 else { return nil }
        throughSeq = value
    }

    public static let method = "chat.tryAnotherApproach"
}
