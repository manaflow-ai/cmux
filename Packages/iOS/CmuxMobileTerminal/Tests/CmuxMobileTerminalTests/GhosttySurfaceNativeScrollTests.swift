#if canImport(UIKit)
import CMUXMobileCore
import GhosttyKit
import Testing
import UIKit

@testable import CmuxMobileTerminal

@Suite("Ghostty surface native scrolling")
struct GhosttySurfaceNativeScrollTests {
    @MainActor
    @Test("sub-row movement accumulates before the viewport crosses a row")
    func subRowMovementAccumulates() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = NativeScrollTestDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate)
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        controller.view.addSubview(view)
        view.frame = window.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            view.prepareForDismantle()
            window.isHidden = true
        }

        let history = (0..<200)
            .map { "native-scroll-line-\($0)\r\n" }
            .joined()
        #expect(await view.processOutputAndWait(Data(history.utf8)))
        #expect(await view.processOutputAndWait(Data()))

        let surface = try #require(view.surface)
        var bottom = ghostty_surface_scrollbar_s()
        #expect(ghostty_surface_scrollbar(surface, &bottom))
        #expect(bottom.total > bottom.len)

        let maximumOffset = bottom.total - bottom.len
        var positioned = ghostty_surface_scrollbar_s()
        #expect(
            ghostty_surface_scroll_to_row_if_revision(
                surface,
                maximumOffset,
                bottom.row_space_revision,
                &positioned
            )
        )
        #expect(positioned.offset == maximumOffset)

        view.applyLocalScrollbackScroll(lines: 0.25, col: 0, row: 0)
        #expect(await view.processOutputAndWait(Data()))

        var afterQuarterRow = ghostty_surface_scrollbar_s()
        #expect(ghostty_surface_scrollbar(surface, &afterQuarterRow))
        #expect(
            afterQuarterRow.offset == maximumOffset,
            "a quarter-row drag must remain in Ghostty's precise-scroll accumulator"
        )

        view.applyLocalScrollbackScroll(lines: 0.75, col: 0, row: 0)
        #expect(await view.processOutputAndWait(Data()))

        var afterFullRow = ghostty_surface_scrollbar_s()
        #expect(ghostty_surface_scrollbar(surface, &afterFullRow))
        #expect(afterFullRow.offset + 1 == maximumOffset)
    }
}

@MainActor
private final class NativeScrollTestDelegate: GhosttySurfaceViewDelegate {
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
#endif
