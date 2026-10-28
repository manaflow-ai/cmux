import CoreGraphics
@testable import CmuxNextTerminal
import Testing

/// A terminal's backing scale reaches its root layer before its Ghostty surface (``TerminalContentScale``):
/// ghostty-next's renderer copies the root layer's `contentsScale` to its own layer on each
/// `ghostty_surface_set_content_scale` (src/renderer/metal/DrawablePresenter.zig), so a surface given the new
/// scale while the root layer still has the old one draws at the old scale.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct TerminalContentScaleTests {
    /// A root layer and surface that record each call, with the root layer's scale at the time of each
    /// content scale (what the renderer copies).
    final class Recorder: TerminalScaleTarget {
        enum Call: Equatable {
            case rootLayer(CGFloat)
            /// The scale given, and the root layer's scale when it came.
            case contentScale(CGSize, rootLayerAtCall: CGFloat?)
            case display(UInt32)
        }

        var rootLayerScale: CGFloat?
        private(set) var calls: [Call] = []

        init(rootLayerScale: CGFloat?) {
            self.rootLayerScale = rootLayerScale
        }

        func setRootLayerScale(_ scale: CGFloat) {
            rootLayerScale = scale
            calls.append(.rootLayer(scale))
        }

        func setContentScale(_ scale: CGSize) {
            calls.append(.contentScale(scale, rootLayerAtCall: rootLayerScale))
        }

        func setDisplayID(_ id: UInt32) {
            calls.append(.display(id))
        }
    }

    private func backing(_ scale: CGFloat, display: UInt32? = 1) -> TerminalBacking {
        TerminalBacking(windowScale: scale, contentScale: CGSize(width: scale, height: scale), displayID: display)
    }

    @Test func aBackingChangeFromOneXToTwoXSetsTheRootLayerBeforeTheSurface() {
        let target = Recorder(rootLayerScale: 1)
        var scale = TerminalContentScale()
        scale.apply(backing(1), to: target)
        #expect(target.calls == [.contentScale(CGSize(width: 1, height: 1), rootLayerAtCall: 1), .display(1)])

        scale.apply(backing(2), to: target)
        #expect(Array(target.calls.dropFirst(2)) == [.rootLayer(2), .contentScale(CGSize(width: 2, height: 2), rootLayerAtCall: 2)],
                "the surface got 2x while the root layer was still at the old scale: \(target.calls)")
    }

    @Test func onlyWhatChangedGoesAgain() {
        let target = Recorder(rootLayerScale: 2)
        var scale = TerminalContentScale()
        scale.apply(backing(2), to: target)
        let first = target.calls.count
        scale.apply(backing(2), to: target)
        #expect(target.calls.count == first, "an unchanged backing called again: \(target.calls)")

        scale.apply(backing(2, display: 7), to: target)
        #expect(Array(target.calls.dropFirst(first)) == [.display(7)])
        #expect(scale.appliedDisplayID == 7)
    }

    @Test func outsideAWindowNeitherTheRootLayerNorTheDisplayChange() {
        let target = Recorder(rootLayerScale: 2)
        var scale = TerminalContentScale()
        scale.apply(TerminalBacking(windowScale: nil, contentScale: CGSize(width: 1, height: 1), displayID: nil), to: target)
        #expect(target.calls == [.contentScale(CGSize(width: 1, height: 1), rootLayerAtCall: 2)])
        #expect(scale.appliedDisplayID == nil)
    }
}
