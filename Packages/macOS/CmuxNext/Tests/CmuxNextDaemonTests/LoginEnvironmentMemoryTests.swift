import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The login environment as a memory consumer: it holds one environment, the
/// store's copy until this launch's capture lands and the capture after, and reports it; a release
/// never drops the capture, so a new terminal never pays a login shell for memory.
struct LoginEnvironmentMemoryTests {
    private static let capture = ["PATH": "/captured/bin", "HOME": "/Users/test"]
    private static let captureBytes = "PATH/captured/binHOME/Users/test".utf8.count

    @Test func theStoresCopyGoesWhenTheCaptureLandsAndTheCaptureStaysThroughARelease() async {
        let cache = LoginEnvironmentCache(store: .holding(path: "/remembered/bin"), capture: { _ in Self.capture })
        #expect(await cache.immediate()?["PATH"] == "/remembered/bin")
        #expect(await cache.updateMemoryLimit(.default)?.entries == 1, "the store's copy is held until the capture lands")

        await cache.start()
        #expect(await cache.captureEnded() == Self.capture)

        let afterCapture = await cache.updateMemoryLimit(.default)
        #expect(afterCapture == MemoryUsage(footprintBytes: Self.captureBytes, entries: 1),
                "the store's copy stayed next to the capture")
        let afterRelease = await cache.releaseMemory(downTo: .criticalThreshold)
        #expect(afterRelease == MemoryUsage(footprintBytes: Self.captureBytes, entries: 1))
        #expect(await cache.value() == Self.capture, "a release dropped the capture")
    }

    @Test func aReleaseBeforeTheCaptureKeepsTheStoresCopy() async {
        let cache = LoginEnvironmentCache(store: .holding(path: "/remembered/bin"), capture: { _ in Self.capture })
        #expect(await cache.immediate()?["PATH"] == "/remembered/bin")

        #expect(await cache.releaseMemory(downTo: .criticalThreshold)?.entries == 1)
        #expect(await cache.immediate()?["PATH"] == "/remembered/bin", "a release left the launch without an environment")
        let started = await cache.captureStarted
        #expect(!started, "a release started a login shell")
    }

    /// A registry that keeps what is added and calls nothing.
    @MainActor private final class FakeRegistry: MemoryConsumerRegistry {
        var entries: [MemoryConsumerEntry] = []

        func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
            entries.append(entry)
        }
    }

    @MainActor @Test func theEnvironmentRegistersUnderItsNameAndKeepsItsRegistration() {
        let registry = FakeRegistry()
        let cache = LoginEnvironmentCache(store: nil, capture: { _ in nil })

        cache.registerMemoryConsumer(with: registry, hop: AsyncMemoryConsumerHop { _ in })

        #expect(registry.entries.map(\.name) == ["login-environment"])
        #expect(registry.entries.first?.traits == LoginEnvironmentCache.memoryTraits)
        #expect(registry.entries.first?.isLive == true, "the cache did not keep its registration")
    }
}

private extension LoginEnvironmentStore {
    /// A store whose file holds `path` (nil: nothing remembered) and drops every save.
    static func holding(path: String?) -> LoginEnvironmentStore {
        let data = path.flatMap { path in
            try? JSONEncoder().encode(Record(version: version, environment: ["PATH": path, "HOME": "/Users/test"]))
        }
        return LoginEnvironmentStore(read: { data }, write: { _ in })
    }
}
