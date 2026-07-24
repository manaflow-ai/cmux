#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import Testing
import UIKit

@testable import CmuxMobileTerminal

@MainActor
@Suite("Verified replay mounted normalization")
struct VerifiedReplayMountedNormalizationTests {
    private final class Delegate: NSObject, GhosttySurfaceViewDelegate {
        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didProduceInput data: Data
        ) {}

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didResize size: TerminalGridSize,
            reportID: UInt64
        ) {}
    }

    @Test("submission resolves an inherited cursor against the mounted theme")
    func submissionUsesMountedThemeCursor() throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = Delegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        defer {
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
        }

        let observed = try MobileTerminalRenderGridFrame(
            surfaceID: "surface",
            stateSeq: 1,
            renderEpoch: "epoch",
            renderRevision: 1,
            columns: 80,
            rows: 24,
            rowSpans: [],
            terminalCursorColor: "#98989d"
        )
        let read = VerifiedReplaySurfaceRead(
            surface: try #require(view.surface),
            generation: view.surfaceGeneration,
            surfaceID: "surface",
            stateSeq: 1,
            renderEpoch: "epoch",
            renderRevision: 1,
            expectedCursorColor: nil,
            configuredCursorColor: "#98989D"
        )

        let normalized = view.normalizedVerifiedReplayObservedFrameForSubmission(
            observed,
            read: read
        )

        #expect(normalized.terminalCursorColor == nil)
    }
}
#endif
