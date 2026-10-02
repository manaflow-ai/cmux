import Foundation

/// What the role step learned about the user, kept in the onboarding state
/// file. Later steps tailor their suggestions to it.
public nonisolated struct OnboardingProfile: Codable, Equatable, Sendable {
    /// The picked role; nil when the user described their work instead.
    public var role: OnboardingRole?
    /// "Describe something else", trimmed; nil when empty.
    public var otherRole: String?
    /// "Suggest personalized tasks".
    public var suggestTasks: Bool

    public init(role: OnboardingRole? = nil, otherRole: String? = nil, suggestTasks: Bool = false) {
        self.role = role
        self.otherRole = otherRole
        self.suggestTasks = suggestTasks
    }

    /// True when the user said something about their work.
    public var isEmpty: Bool { role == nil && otherRole == nil }
}
