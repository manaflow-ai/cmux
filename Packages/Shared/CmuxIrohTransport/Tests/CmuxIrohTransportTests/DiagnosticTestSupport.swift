import CMUXMobileCore
import Foundation

func waitForDiagnosticProcessedCount(
    _ log: DiagnosticLog,
    atLeast expectedCount: Int,
    timeout: Duration = .seconds(2)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await log.processedCount() >= expectedCount { return true }
        await Task.yield()
    }
    return await log.processedCount() >= expectedCount
}
