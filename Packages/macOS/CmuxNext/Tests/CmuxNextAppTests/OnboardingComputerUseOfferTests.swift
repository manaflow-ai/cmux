@testable import CmuxNextApp
import CmuxNextAgentActivity
import CmuxNextOnboarding
import Darwin
import Foundation
import Testing

/// The computer use step is offered whenever the cmux-cua helper is
/// reachable: a helper that comes up after onboarding first asked still
/// gets the step, and asking for the step while another onboarding window
/// shows opens it.
@MainActor
@Suite struct OnboardingComputerUseOfferTests {
    @Test func theSourceAppearsOnceTheHelperSocketComesUp() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let path = FileManager.default.temporaryDirectory.appending(path: "cu-\(UUID().uuidString.prefix(8)).sock").path
        defer { unlink(path) }
        services.onboarding.computerUseConfiguration = .init(socketPath: path, machineName: "")
        let onboarding = AppOnboardingServices(owner: services.onboarding)
        #expect(onboarding.computerUsePermissions == nil, "no helper yet")
        // The helper comes up after the first query.
        let listener = try #require(ComputerUsePermissionSourceTests.bound(path))
        defer { close(listener) }
        listen(listener, 1)
        #expect(onboarding.computerUsePermissions != nil, "the step is offered once the helper listens")
    }

    @Test func askingForAStepTheOpenWindowLacksRebuildsIt() {
        let firstRun: [OnboardingModel.Step] = [.accounts, .importData]
        #expect(OnboardingService.reusesWindow(showing: firstRun, for: nil))
        #expect(OnboardingService.reusesWindow(showing: firstRun, for: .importData))
        #expect(!OnboardingService.reusesWindow(showing: firstRun, for: .computerUse))
    }
}
