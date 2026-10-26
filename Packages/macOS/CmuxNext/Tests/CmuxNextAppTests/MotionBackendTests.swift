import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// The motion backend seam (p03-rendering-019): a kind runs on the render server only while
/// `motion.renderServer` is on and the kind registered a variant; off (the default), no variant is
/// called and every kind stays on the CPU step.
@MainActor @Suite struct MotionBackendTests {
    final class Host {
        var begun: [LayoutMotionKind] = []
    }

    struct Variant: RenderServerMotion {
        let kind: LayoutMotionKind
        var takes = true
        func begin(on host: Host, policy: MotionPolicy) -> Bool {
            host.begun.append(kind)
            return takes
        }
    }

    static let policy = MotionPolicy(speed: .fast, reduceMotion: false)

    @Test func theTunableIsOffByDefault() {
        #expect(LayoutTunables.motionRenderServer.defaultValue == false)
        #expect(LayoutTunables.motionRenderServer.key == "motion.renderServer")
        #expect(LayoutTunables.all.contains { $0.key == "motion.renderServer" })
    }

    @Test func offEveryKindStepsOnTheCPUAndNoVariantRuns() {
        let backends = MotionBackends<Host>([Variant(kind: .splitClose), Variant(kind: .zoom)], renderServer: { false })
        for kind in LayoutMotionKind.allCases { #expect(backends.backend(for: kind) == .cpuStep) }
        let host = Host()
        #expect(backends.begin(on: host, policy: Self.policy).isEmpty)
        #expect(host.begun.isEmpty)
    }

    @Test func onOnlyRegisteredKindsRunOnTheRenderServer() {
        let backends = MotionBackends<Host>([Variant(kind: .splitClose), Variant(kind: .camera)], renderServer: { true })
        for kind in LayoutMotionKind.allCases {
            #expect(backends.backend(for: kind) == ([.splitClose, .camera].contains(kind) ? .renderServer : .cpuStep))
        }
    }

    @Test func beginRunsEachVariantInOrderAndReportsTheKindsThatTookAMotion() {
        let backends = MotionBackends<Host>([Variant(kind: .splitClose), Variant(kind: .zoom, takes: false), Variant(kind: .rows)],
                                            renderServer: { true })
        let host = Host()
        #expect(backends.begin(on: host, policy: Self.policy) == [.splitClose, .rows])
        #expect(host.begun == [.splitClose, .zoom, .rows])
    }

    @Test func aKindRegisteredTwiceKeepsItsFirstVariant() {
        let backends = MotionBackends<Host>([Variant(kind: .zoom), Variant(kind: .zoom, takes: false)], renderServer: { true })
        let host = Host()
        #expect(backends.registeredKinds == [.zoom])
        #expect(backends.begin(on: host, policy: Self.policy) == [.zoom])
        #expect(host.begun == [.zoom])
    }

    @Test func nothingRegisteredReadsNoTunable() {
        var reads = 0
        let backends = MotionBackends<Host>([], renderServer: { reads += 1; return true })
        #expect(backends.begin(on: Host(), policy: Self.policy).isEmpty)
        #expect(reads == 0)
    }

    /// Each kind registers once on a screen (tasks 022a-033 add one line each).
    @Test func theScreensRegistrationListsEachKindOnce() {
        let kinds = ScreenContentView.renderServerMotions.map(\.kind)
        #expect(Set(kinds).count == kinds.count)
    }
}
