#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import GhosttyKit
import Testing
import UIKit

@testable import CmuxMobileTerminal

@MainActor
@Suite("Full replacement scroll position", .serialized)
struct FullReplacementScrollPositionTests {
    private final class Delegate: NSObject, GhosttySurfaceViewDelegate {
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}
        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didResize size: TerminalGridSize,
            reportID: UInt64
        ) {}
    }

    private struct Harness {
        let window: UIWindow
        let view: GhosttySurfaceView
        let delegate: Delegate
    }

    private func makeHarness() throws -> Harness {
        let runtime = try GhosttyRuntime.shared()
        let delegate = Delegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        window.addSubview(view)
        view.frame = window.bounds
        window.isHidden = false
        view.layoutIfNeeded()
        return Harness(window: window, view: view, delegate: delegate)
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return predicate()
    }

    private func scrollbarDistanceFromBottom(_ view: GhosttySurfaceView) -> UInt64? {
        guard let surface = view.surface else { return nil }
        var snapshot = ghostty_surface_scrollbar_s()
        guard ghostty_surface_scrollbar(surface, &snapshot) else { return nil }
        let maximumOffset = snapshot.total > snapshot.len ? snapshot.total - snapshot.len : 0
        return maximumOffset - min(snapshot.offset, maximumOffset)
    }

    private func fullFrame(from view: GhosttySurfaceView) throws -> MobileTerminalRenderGridFrame {
        let surface = try #require(view.surface)
        let surfaceID = "full-replacement-scroll-position"
        let exported = surfaceID.withCString { pointer in
            ghostty_surface_render_grid_json_with_theme(
                surface,
                pointer,
                UInt(surfaceID.utf8.count),
                1,
                500,
                true
            )
        }
        defer { ghostty_string_free(exported) }
        let pointer = try #require(exported.ptr)
        let data = Data(bytes: pointer, count: Int(exported.len))
        return try JSONDecoder().decode(MobileTerminalRenderGridFrame.self, from: data)
    }

    @Test("authoritative full replay keeps the phone-local viewport in history")
    func fullReplayPreservesDistanceFromBottom() async throws {
        let harness = try makeHarness()
        defer { harness.view.prepareForDismantle() }

        let seed = (1...300)
            .map { String(format: "full-replay line %03d\r\n", $0) }
            .joined()
        #expect(await harness.view.processOutputAndWait(Data(seed.utf8)))
        let frame = try fullFrame(from: harness.view)

        harness.view.applyLocalScrollbackScroll(lines: 60, col: 2, row: 2)
        #expect(await waitUntil {
            (scrollbarDistanceFromBottom(harness.view) ?? 0) >= 40
        })
        let before = try #require(scrollbarDistanceFromBottom(harness.view))

        #expect(
            await harness.view.processFullReplacementOutputAndWait(
                frame.vtPatchBytes(),
                terminalConfigTheme: frame.terminalConfigTheme
            )
        )
        let after = try #require(scrollbarDistanceFromBottom(harness.view))

        #expect(after == before, "full replay moved the viewport from \(before) rows above bottom to \(after)")
    }
}
#endif
