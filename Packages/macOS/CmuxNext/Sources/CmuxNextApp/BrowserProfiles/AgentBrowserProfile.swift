import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDaemonService
import CmuxNextWakeups
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

    static let id = BrowserPageService.agentBrowserProfileID

    static var name: String {
        String(localized: "handlers.misc.agentBrowserProfile.name", defaultValue: "Agents", table: "MiscHandlers", bundle: .module)
    }

    /// nil: not "agent" and not a profile id.
    static func request(_ raw: String?) -> Request? {
        guard let raw, !raw.isEmpty else { return .cascade }
        if raw.lowercased() == "agent" { return .agent }
        return BrowserProfileRecord.isValidID(raw) ? .explicit(raw) : nil
    }

    /// The agent profile's id, created when missing (an existing record is
    /// kept). With daemon-owned records the create reply can arrive before
    /// the record reaches this app's mirror, and a tab opened then would fall
    /// back to the workspace's profile (the cascade only takes known ids), so
    /// this waits for the record to be reported, at most `deadline`.
    ///
    /// R-wait: one ``ObservedCondition`` (a `ServiceObservation` in the automation class: an agent's
    /// `openBrowser` asked) reads the profile list again only when it changes, bounded by a `MainDeadline`.
    static func ensure(_ profiles: BrowserProfileService, deadline: Duration = .seconds(5)) async throws -> String {
        if profiles.isKnown(id) { return id }
        _ = try await profiles.createProfile(id: id, name: name, color: nil, icon: nil)
        guard let services = profiles.services else { throw AppServicesReference.closing }
        try await reported(within: deadline, on: services.mainWork, deadlines: services.mainDeadlines) { profiles.isKnown(id) }
        return id
    }

    /// Returns once `known` holds (at once when it holds now); throws ``NotReported`` when it still does not
    /// after `deadline` on `deadlines`.
    static func reported(within deadline: Duration, on work: MainWorkScheduler, deadlines: MainDeadlineScheduler,
                         _ known: @escaping @MainActor () -> Bool) async throws(NotReported) {
        await ObservedCondition(owner: "AgentBrowserProfile.ensure", .automation, on: work).until(timeout: deadline, deadlines: deadlines, known)
        guard known() else { throw NotReported() }
    }

    nonisolated struct NotReported: Error, CustomStringConvertible {
        var description: String { "the agent browser profile was created but not reported back by the home daemon" }
    }
}
