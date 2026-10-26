import CmuxNextBrowser
import CmuxNextControl
import CmuxNextWakeups
import Foundation
import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

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
    static func ensure(_ profiles: BrowserProfileService, deadline: Duration = .seconds(5)) async throws -> String {
        if profiles.isKnown(id) { return id }
        _ = try await profiles.createProfile(id: id, name: name, color: nil, icon: nil)
        if profiles.isKnown(id) { return id }
        let timer = DemandTimer(owner: "AgentBrowserProfile.ensure")
        // The record or the deadline, whichever comes first; the winner stops the other.
        try await withOnceThrowingContinuation { (once: OnceContinuation<Void, any Error>) in
            // Event-driven: the profile list is observable state of the home store.
            let watch = Task { @MainActor in
                for await known in ObservationStream({ profiles.isKnown(id) }) where known {
                    // The deadline won and cancelled this watch: its resume is spent.
                    guard !Task.isCancelled else { return }
                    if once.resume(returning: ()) { timer.cancel() }
                    return
                }
            }
            timer.schedule(after: deadline) {
                if once.resume(throwing: NotReported()) { watch.cancel() }
            }
        }
        return id
    }

    nonisolated struct NotReported: Error, CustomStringConvertible {
        var description: String { "the agent browser profile was created but not reported back by the home daemon" }
    }
}
