#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import Foundation
import GhosttyKit
import Testing
import UIKit

@testable import CmuxMobileTerminal

@MainActor
@Suite("Authoritative scrollback positioning", .serialized)
struct AuthoritativeScrollbackPositionTests {
    private final class Delegate: NSObject, GhosttySurfaceViewDelegate {
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {}
    }

    @MainActor
    private struct Harness {
        let window: UIWindow
        let view: GhosttySurfaceView
        let delegate: Delegate

        func tearDown() {
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
        }
    }

    @Test("authoritative replay position and following reversal complete in causal order")
    func replayPositionAndReversalCompleteInOrder() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let mounted = await waitUntil(timeout: .seconds(5)) {
            harness.view.surface != nil
        }
        #expect(mounted)
        let surface = try #require(harness.view.surface)
        let geometrySettled = await waitUntil(timeout: .seconds(5)) {
            ghostty_surface_size(surface).rows > 17
        }
        #expect(geometrySettled)
        let rowsFromBottom = 16
        let followingRowsTowardBottom = 5
        let outputApplied = await harness.view.processOutputAndWait(
            Self.longOutput,
            scrollbackOffsetFromBottomRows: rowsFromBottom,
            authoritativeReconstructedRowCount: 320,
            followingScrollRuns: [
                MobileTerminalScrollRun(
                    primaryRows: -followingRowsTowardBottom,
                    alternateScreenLines: -Double(followingRowsTowardBottom),
                    col: 0,
                    row: 0
                ),
            ]
        )
        #expect(outputApplied)

        // Queue a no-op output behind every action scheduled by first-output
        // handling so the assertion observes the completed delivery lifecycle.
        #expect(await harness.view.processOutputAndWait(Data()))

        var positioned = ghostty_surface_scrollbar_s()
        #expect(ghostty_surface_scrollbar(surface, &positioned))
        let maximumOffset = positioned.total > positioned.len
            ? positioned.total - positioned.len
            : 0
        let expectedOffset = maximumOffset
            - UInt64(rowsFromBottom)
            + UInt64(followingRowsTowardBottom)
        #expect(
            positioned.offset == expectedOffset,
            "first-output bottom handling or queued positioning overwrote the newer reversal"
        )
    }

    private func makeHarness() throws -> Harness {
        let runtime = try GhosttyRuntime.shared()
        let delegate = Delegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return Harness(window: window, view: view, delegate: delegate)
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
                try await clock.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }
        return predicate()
    }

    private static let longOutput = Data(
        (0..<320)
            .map { String(format: "POSITION-ROW-%04d", $0) }
            .joined(separator: "\r\n")
            .utf8
    )
}
#endif
