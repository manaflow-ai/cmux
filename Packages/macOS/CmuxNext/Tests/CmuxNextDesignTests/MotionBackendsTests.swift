import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// The motion backend seam: a host's variants run only while the render server
/// is selected; off, or with nothing registered, no variant runs and every kind stays on the CPU.
@MainActor @Suite struct MotionBackendsTests {
    final class FakeHost {
        var begun: [RenderMotionKind] = []
    }

    struct FakeVariant: RenderServerMotion {
        typealias Host = FakeHost
        let kind: RenderMotionKind
        var backend: MotionBackend = .renderServer
        func begin(on host: FakeHost, policy: MotionPolicy) -> MotionBackend {
            host.begun.append(kind)
            return backend
        }
    }

    static let policy = MotionPolicy(speed: .fast, reduceMotion: false)

    @Test func offNoVariantRuns() {
        let backends = MotionBackends<FakeHost>([FakeVariant(kind: .splitClose), FakeVariant(kind: .zoom)], renderServer: { false })
        let host = FakeHost()
        #expect(!backends.isLive)
        #expect(backends.begin(on: host, policy: Self.policy).isEmpty)
        #expect(host.begun.isEmpty)
    }

    @Test func onEachVariantRunsInOrderAndOnlyTheKindsItTookAreOnTheRenderServer() {
        let backends = MotionBackends<FakeHost>([FakeVariant(kind: .splitClose), FakeVariant(kind: .zoom, backend: .cpuStep),
                                                 FakeVariant(kind: .rows)],
                                                renderServer: { true })
        let host = FakeHost()
        #expect(backends.isLive)
        #expect(backends.begin(on: host, policy: Self.policy) == [.splitClose, .rows])
        #expect(host.begun == [.splitClose, .zoom, .rows])
    }

    @Test func nothingRegisteredReadsNoSwitch() {
        var reads = 0
        let backends = MotionBackends<FakeHost>([], renderServer: {
            reads += 1
            return true
        })
        #expect(!backends.isLive)
        #expect(backends.begin(on: FakeHost(), policy: Self.policy).isEmpty)
        #expect(reads == 0)
    }
}
