import Foundation

/// The Cloud chat's latest-turn-only machine + transcript fork. The app owns the operation so the
/// page cannot accidentally mutate or select the parent while a child is being prepared.
public nonisolated struct AgentPaneTryAnotherApproach: Equatable, Sendable {
    public let throughSeq: Int

    public init?(params: [String: Any]?) {
        guard let params, Set(params.keys) == ["throughSeq"] else { return nil }
        // A whole positive number only: NSNumber would coerce a boolean or 6.5 to a turn.
        guard let number = params["throughSeq"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int(exactly: number.doubleValue), value > 0 else { return nil }
        throughSeq = value
    }

    public static let method = "chat.tryAnotherApproach"
}
