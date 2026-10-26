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
        try await withOnceThrowingContinuation { (once: OnceContinuation<Void, any Error>) in
            let race = ReportRace(once)
            // Event-driven: the profile list is observable state of the home store.
            race.watch = Task { @MainActor in
                for await known in ObservationStream({ profiles.isKnown(id) }) where known {
                    race.finish(.success(()))
                    return
                }
            }
            race.timer.scheduleOnMain(after: deadline) { race.finish(.failure(NotReported())) }
        }
        return id
    }

    /// The record against the deadline. Both producers run on the main actor, and the first
    /// one answers, then stops the other, in one turn; the loser finds the race settled.
    @MainActor
    private final class ReportRace {
        private var continuation: OnceContinuation<Void, any Error>?
        let timer = DemandTimer(owner: "AgentBrowserProfile.ensure")
        var watch: Task<Void, Never>?

        init(_ continuation: OnceContinuation<Void, any Error>) { self.continuation = continuation }

        func finish(_ result: Result<Void, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
            timer.cancel()
            watch?.cancel()
        }
    }

    nonisolated struct NotReported: Error, CustomStringConvertible {
        var description: String { "the agent browser profile was created but not reported back by the home daemon" }
    }
}
