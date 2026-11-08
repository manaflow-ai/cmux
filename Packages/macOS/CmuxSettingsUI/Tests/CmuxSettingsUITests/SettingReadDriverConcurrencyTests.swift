import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite struct SettingReadDriverConcurrencyTests {
    @Test func activationIsClaimedBeforeTheStreamFactoryCanReenter() {
        let driver = SettingReadDriver<Int>()
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        defer { continuation.finish() }
        var streamCreations = 0

        driver.activate({
            streamCreations += 1
            driver.activate({
                streamCreations += 1
                return stream
            }, sink: { _ in })
            return stream
        }, sink: { _ in })

        #expect(streamCreations == 1)
    }
}
