import CoreGraphics
import Testing
@testable import CmuxNextRemoteBrowser

#if DEBUG
/// `rb.open` carries the pane's real size: the session opens only once the
/// rd session streams AND the page view has a non-empty layout, whichever
/// comes last (never a 1x1 placeholder screen).
@Suite(.timeLimit(.minutes(1)))
struct RemoteBrowserOpenGateTests {
    private static let empty = RemoteBrowserViewport(bounds: .zero, backingScale: 2)
    private static let real = RemoteBrowserViewport(bounds: CGSize(width: 800, height: 600), backingScale: 2)

    @Test func streamingBeforeLayoutWaitsForTheFirstRealViewport() {
        var gate = RemoteBrowserOpenGate()
        #expect(gate.viewport(Self.empty) == nil)
        #expect(gate.streaming() == nil)
        #expect(gate.viewport(Self.empty) == nil)
        #expect(gate.viewport(Self.real) == .open(RbScreen(viewport: Self.real)))
    }

    @Test func layoutBeforeStreamingOpensWhenTheSessionStreams() {
        var gate = RemoteBrowserOpenGate()
        #expect(gate.viewport(Self.real) == nil)
        #expect(gate.streaming() == .open(RbScreen(viewport: Self.real)))
        #expect(gate.streaming() == nil)
    }

    @Test func afterOpenOnlyRealSizeChangesResize() {
        var gate = RemoteBrowserOpenGate()
        _ = gate.viewport(Self.real)
        _ = gate.streaming()
        #expect(gate.viewport(Self.real) == nil)
        #expect(gate.viewport(Self.empty) == nil)
        let wider = RemoteBrowserViewport(bounds: CGSize(width: 1024, height: 600), backingScale: 2)
        #expect(gate.viewport(wider) == .resize(RbScreen(viewport: wider)))
    }

    @Test func aViewportKnowsWhenItHasNoArea() {
        #expect(Self.empty.isEmpty)
        #expect(RemoteBrowserViewport(bounds: CGSize(width: 0.5, height: 300), backingScale: 2).isEmpty)
        #expect(!Self.real.isEmpty)
    }
}
#endif
