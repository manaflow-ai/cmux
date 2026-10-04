import CmuxNextBrowser
import Foundation

/// openBrowser's optional `profile` argument (plans/cmux-next/passwords.md,
/// section 3.4). "agent" asks for the clean agent profile: one profile with a
/// fixed id that cmux creates on first use, with no extensions and no cookies
/// shared with the person's profiles, so an agent can drive its pages while
/// the interim extension guard refuses tabs in profiles with extensions. A
/// session the person wants the agent to use goes through the Secure sign-in
/// sheet. Any other value must name an existing profile; an unknown one is
/// refused rather than falling back to the workspace's profile.
enum AgentBrowserProfile {
    enum Request: Equatable {
        /// No argument: the workspace's, the space's, or `default`.
        case cascade
        case explicit(String)
        case agent
    }

    static let id = "a9e70000-0000-4000-8000-00000000c0de"

    static var name: String {
        String(localized: "handlers.misc.agentBrowserProfile.name", defaultValue: "Agents", table: "MiscHandlers", bundle: .module)
    }

    /// nil: not "agent" and not a profile id.
    static func request(_ raw: String?) -> Request? {
        guard let raw, !raw.isEmpty else { return .cascade }
        if raw.lowercased() == "agent" { return .agent }
        return BrowserProfileRecord.isValidID(raw) ? .explicit(raw) : nil
    }

    /// The agent profile's id, created when missing (an existing record is kept).
    static func ensure(_ profiles: BrowserProfileService) async throws -> String {
        if profiles.isKnown(id) { return id }
        return try await profiles.createProfile(id: id, name: name, color: nil, icon: nil)
    }
}
