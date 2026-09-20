#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import GhosttyKit
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// Exercises the surface boundary used by local Linux lanes when a SwiftUI
/// destination is detached and attached again. The lane replays its retained
/// bytes on every new attachment, while the UIKit surface keeps its terminal
/// model across a transient window detach.
@MainActor
@Suite("Local terminal replay lifecycle", .serialized)
struct LocalTerminalReplayLifecycleTests {
    @Test("a replay clears terminal state retained across window detach")
    func replayClearsRetainedTerminalStateAfterDetach() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = Delegate()
        let view = GhosttySurfaceView(
            runtime: runtime,
            delegate: delegate,
            fontSize: 10,
            isMacRemote: false
        )
        view.autoFocusOnWindowAttach = false
        // Rendering is unrelated to this assertion. Suppressing it keeps the
        // test focused on the serialized VT model and avoids GPU timing.
        view.isRenderDispatchSuppressed = true

        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        controller.view.addSubview(view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            view.isRenderDispatchSuppressed = false
            view.prepareForDismantle()
            window.isHidden = true
        }

        let marker = "cmux-replay-marker"
        let freshMarker = "cmux-replay-fresh"
        #expect(await view.processOutputAndWait(Data("\(marker)\r\n".utf8)))
        let beforeDetach = try #require(
            view.renderedTextForTesting(pointTag: GHOSTTY_POINT_SCREEN)
        )
        #expect(beforeDetach.contains(marker))

        // This is the transient path used by a scene/window transition. The
        // Ghostty surface remains alive, so its previous marker remains in
        // the terminal model until the replacement lane sends its replay.
        view.removeFromSuperview()
        controller.view.addSubview(view)
        window.layoutIfNeeded()
        #expect(view.window === window)

        // Keep the original marker in the replay so a missing RIS would
        // produce two copies. The second marker proves the replay operation
        // itself completed instead of allowing the old text to satisfy the
        // polling predicate.
        view.processTerminalReplay(Data("\(marker)\r\n\(freshMarker)\r\n".utf8))
        let replayApplied = await waitUntil(timeout: .seconds(2)) {
            guard let text = view.renderedTextForTesting(pointTag: GHOSTTY_POINT_SCREEN) else {
                return false
            }
            return text.contains(freshMarker)
        }
        #expect(replayApplied)

        let afterReplay = try #require(
            view.renderedTextForTesting(pointTag: GHOSTTY_POINT_SCREEN)
        )
        let markerCount = afterReplay.components(separatedBy: marker).count - 1
        #expect(markerCount == 1)
        #expect(afterReplay.contains(freshMarker))
    }

    private func waitUntil(
        timeout: Duration,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if predicate() { return true }
            do {
                try await clock.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return predicate()
    }

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
}
#endif
