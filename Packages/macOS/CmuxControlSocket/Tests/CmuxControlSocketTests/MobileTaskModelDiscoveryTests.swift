import Foundation
import Testing
@testable import CmuxControlSocket

private actor MobileTaskModelDiscoveryProbe {
    private(set) var commandCount = 0
    private(set) var now = Date(timeIntervalSince1970: 1_000)

    func run(_ command: String, timeout: Duration) -> String? {
        commandCount += 1
        return "opencode/dynamic-\(commandCount)"
    }

    func currentDate() -> Date {
        now
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

@Suite("Mobile task model discovery cache")
struct MobileTaskModelDiscoveryTests {
    @Test func cacheUsesInjectedClockAndExpiresAfterTenMinutes() async {
        let probe = MobileTaskModelDiscoveryProbe()
        let strategy = MobileTaskModelProviderStrategy(
            homeDirectory: URL(fileURLWithPath: "/Users/tester"),
            commandRunner: { command, timeout in
                await probe.run(command, timeout: timeout)
            },
            fileReader: { _ in nil }
        )
        let discovery = MobileTaskModelDiscovery(
            strategy: strategy,
            now: { await probe.currentDate() }
        )

        let first = await discovery.models(for: .openCode)
        let cached = await discovery.models(for: .openCode)
        #expect(first == cached)
        #expect(await probe.commandCount == 1)

        await probe.advance(
            by: MobileTaskModelDiscovery.defaultCacheTTL - 1
        )
        #expect(await discovery.models(for: .openCode) == first)
        #expect(await probe.commandCount == 1)

        await probe.advance(by: 2)
        let refreshed = await discovery.models(for: .openCode)
        #expect(refreshed.models.first?.id == "opencode/dynamic-2")
        #expect(await probe.commandCount == 2)
    }
}
