@testable import CmuxNextOnboarding
import Testing

/// Opening the Import from Browser tool is already an explicit request to
/// inspect local browser data. Detection should start there, and a slow probe
/// must not expose a misleading Done action while it is running.
@MainActor @Suite(.serialized) struct OnboardingAutomaticDetectionTests {
    private static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func importToolStartsDetectionWithoutAnExtraClick() async {
        let services = MockOnboardingServices()
        let model = OnboardingModel(services: services, step: .importData)

        model.stepDidAppear()
        #expect(model.importer.phase == .detecting)
        #expect(model.primaryTitle == OnboardingStrings.detecting)
        #expect(!model.canAdvance)

        // Return during detection is a no-op; it cannot dismiss the tool while
        // the person is waiting for the browser probe to finish.
        model.next()
        #expect(!model.ended)

        await Self.until { model.importer.phase == .ready }
        #expect(model.canAdvance)
        #expect(services.detections == 1)
    }
}
