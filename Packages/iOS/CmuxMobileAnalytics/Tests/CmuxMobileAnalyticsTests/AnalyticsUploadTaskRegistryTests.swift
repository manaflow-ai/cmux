import Foundation
import Testing

@testable import CmuxMobileAnalytics

@Suite struct AnalyticsUploadTaskRegistryTests {
    @Test func defaultsDisabledAndRejectsRegistration() {
        let registry = AnalyticsUploadTaskRegistry()
        let task = Task<AnalyticsUploadResult, Never> { .accepted }

        #expect(!registry.register(task, id: UUID()))
    }

    @Test func disableCancelsRegisteredTaskBeforeReturning() async {
        let registry = AnalyticsUploadTaskRegistry()
        let gate = TestGate()
        let task = Task<AnalyticsUploadResult, Never> {
            await gate.wait()
            return Task.isCancelled ? .drop : .accepted
        }
        registry.setEnabled(true)
        #expect(registry.register(task, id: UUID()))

        registry.setEnabled(false)

        #expect(task.isCancelled)
        await gate.open()
        #expect(await task.value == .drop)
    }
}
