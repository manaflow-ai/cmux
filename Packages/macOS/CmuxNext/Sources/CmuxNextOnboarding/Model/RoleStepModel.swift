import Foundation
public import Observation

/// Role step: one role from the grid, or a few words of the user's own.
/// Continue saves it; Skip saves nothing. Opening onboarding again (the
/// "Onboarding…" action) starts from what was saved.
@MainActor
@Observable
public final class RoleStepModel {
    public private(set) var role: OnboardingRole?
    /// "Describe something else" as typed.
    public private(set) var otherRole = ""
    public var suggestTasks = false
    @ObservationIgnored private let services: any OnboardingServices

    init(services: any OnboardingServices) {
        self.services = services
        if let saved = services.savedProfile {
            role = saved.role
            otherRole = saved.otherRole ?? ""
            suggestTasks = saved.suggestTasks
        }
    }

    /// Picks a role; typing a description clears it, and the reverse.
    public func select(_ value: OnboardingRole) {
        role = value
        otherRole = ""
    }

    public func describe(_ text: String) {
        otherRole = text
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { role = nil }
    }

    /// What Continue saves.
    public var profile: OnboardingProfile {
        let other = otherRole.trimmingCharacters(in: .whitespacesAndNewlines)
        return OnboardingProfile(role: role, otherRole: other.isEmpty ? nil : other, suggestTasks: suggestTasks)
    }

    /// Continue: saves the answer when there is one.
    func commit() {
        let answer = profile
        guard !answer.isEmpty else { return }
        services.saveProfile(answer)
    }
}
