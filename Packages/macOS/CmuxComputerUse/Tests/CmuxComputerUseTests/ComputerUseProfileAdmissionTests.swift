import Foundation
import Testing
@testable import CmuxComputerUse

/// Agent calls are admitted exactly when Computer Use is enabled and the
/// profile's current helper generation reports both helper-owned TCC grants.
/// The durable onboarding record is presentation history, not an admission input.
@Suite("Computer Use per-profile admission")
@MainActor
struct ComputerUseProfileAdmissionTests {
    private static let granted = ComputerUsePermissionStatus(
        accessibility: true, screenRecording: true, isKnown: true, sourceAttribution: "helper-daemon"
    )
    private static let screenRecordingRevoked = ComputerUsePermissionStatus(
        accessibility: true, screenRecording: false, isKnown: true, sourceAttribution: "helper-daemon"
    )

    /// Synthetic preferences suite and a recorder standing in for both daemons.
    private final class Harness {
        let suite = "ComputerUseProfileAdmission-\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: ComputerUseOnboardingStore
        var statuses: [ComputerUseDaemonProfile: ComputerUsePermissionStatus] = [:]
        var enabled = true
        var published: [ComputerUseDaemonProfile: [Bool]] = [:]
        var completionKey: String { "cmux.computerUse.onboarding.completion.fixture-scope" }

        @MainActor init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            store = ComputerUseOnboardingStore(defaults: defaults, scope: "fixture-scope")
            store.apply(.setEnabled(true))
            store.restore(for: "synthetic-signed-helper")
        }

        @MainActor var admission: ComputerUseProfileAdmissionCoordinator {
            ComputerUseProfileAdmissionCoordinator(
                store: store,
                isEnabled: { self.enabled },
                probe: { self.statuses[$0] },
                publish: { profile, ready in
                    self.published[profile, default: []].append(ready)
                    return true
                }
            )
        }

        @MainActor func commitCompletion() throws {
            let attempt = try #require(store.beginVerification())
            #expect(store.finishVerification(.ready, attempt: attempt) == .ready)
            #expect(defaults.data(forKey: completionKey) != nil)
        }

        func remove() { defaults.removePersistentDomain(forName: suite) }
    }

    @Test func grantedHelperWithoutCompletionRecordIsAdmittedWithoutPresentingSetup() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        harness.statuses = [.native: Self.granted, .codexCompatibility: Self.granted]
        #expect(!harness.store.completionCommitted)

        for profile in ComputerUseDaemonProfile.allCases {
            let outcome = await harness.admission.admit(profile)
            #expect(outcome.acknowledged)
            #expect(outcome.ready)
        }

        #expect(harness.published == [.native: [true], .codexCompatibility: [true]])
        // Admission claims no onboarding presentation and fabricates no record.
        #expect(harness.store.phase == .onboardingRequired)
        #expect(harness.defaults.data(forKey: harness.completionKey) == nil)
    }

    @Test(arguments: ComputerUseDaemonProfile.allCases)
    func oneUnansweredProfileDoesNotBlockTheOther(down: ComputerUseDaemonProfile) async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let up = ComputerUseDaemonProfile.allCases.first { $0 != down }!
        harness.statuses = [up: Self.granted]

        #expect(await harness.admission.admit(down).ready == false)
        #expect(await harness.admission.admit(up).ready)
        #expect(harness.published[up] == [true])
        #expect(harness.published[down] == [false])
    }

    @Test func unansweredStatusProbeKeepsTheCompletionRecord() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        try harness.commitCompletion()
        harness.statuses = [:]

        for profile in ComputerUseDaemonProfile.allCases {
            #expect(await harness.admission.admit(profile).ready == false)
        }

        #expect(harness.store.completionCommitted)
        #expect(harness.store.phase == .ready)
        #expect(harness.defaults.data(forKey: harness.completionKey) != nil)
    }

    @Test func revokedGrantClosesAdmissionAndInvalidatesCompletion() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        try harness.commitCompletion()
        harness.statuses = [.native: Self.screenRecordingRevoked, .codexCompatibility: Self.granted]

        #expect(await harness.admission.admit(.native).ready == false)

        #expect(harness.published[.native] == [false])
        #expect(!harness.store.completionCommitted)
        #expect(harness.defaults.data(forKey: harness.completionKey) == nil)
    }

    @Test func disabledComputerUsePublishesNotReadyDespiteGrants() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        try harness.commitCompletion()
        harness.statuses = [.native: Self.granted, .codexCompatibility: Self.granted]
        harness.enabled = false

        for profile in ComputerUseDaemonProfile.allCases {
            #expect(await harness.admission.admit(profile).ready == false)
        }
        #expect(harness.published == [.native: [false], .codexCompatibility: [false]])
    }

    @Test func hostAttributedOrUnattributedGrantsAreNotAdmission() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        harness.statuses = [
            .native: ComputerUsePermissionStatus(accessibility: true, screenRecording: true, isKnown: true)
        ]
        #expect(await harness.admission.admit(.native).ready == false)
    }
}
