import CoreGraphics
import CmuxWindowing
import Testing

@testable import CmuxWorkspaces

@Suite("SessionWindowFrameResolver")
struct SessionWindowFrameResolverTests {
    private let resolver = SessionWindowFrameResolver()

    @Test("rejects sub-minimum saved frames")
    func rejectsSubMinimumFrame() {
        let display = SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let restored = resolver.resolvedWindowFrame(
            from: CGRect(x: 0, y: 0, width: 100, height: 100),
            display: nil,
            availableDisplays: [display],
            fallbackDisplay: display
        )
        #expect(restored == nil)
    }

    @Test("keeps an intersecting frame without display metadata")
    func keepsIntersectingFrameWithoutDisplayMetadata() throws {
        let display = SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let restored = try #require(
            resolver.resolvedWindowFrame(
                from: CGRect(x: 120, y: 80, width: 500, height: 350),
                display: nil,
                availableDisplays: [display],
                fallbackDisplay: display
            )
        )
        #expect(abs(restored.minX - 120) < 0.001)
        #expect(abs(restored.minY - 80) < 0.001)
        #expect(abs(restored.width - 500) < 0.001)
        #expect(abs(restored.height - 350) < 0.001)
    }

    @Test("remaps a frame onto the fallback display when its origin display is gone")
    func remapsFrameOntoFallbackDisplay() throws {
        // Saved on display 1 (offset to x=1000), but only display 2 (at origin)
        // is attached now: the frame must remap proportionally onto display 2.
        let savedDisplay = SessionSourceDisplaySnapshot(
            displayID: 1,
            frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        )
        let display2 = SessionDisplayGeometry(
            displayID: 2,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let restored = try #require(
            resolver.resolvedWindowFrame(
                from: CGRect(x: 1_200, y: 100, width: 600, height: 400),
                display: savedDisplay,
                availableDisplays: [display2],
                fallbackDisplay: display2
            )
        )
        #expect(display2.visibleFrame.intersects(restored))
        #expect(abs(restored.width - 600) < 0.001)
        #expect(abs(restored.height - 400) < 0.001)
        #expect(abs(restored.minX - 200) < 0.001)
        #expect(abs(restored.minY - 100) < 0.001)
    }

    @Test("startup primary frame falls back to persisted geometry when primary missing")
    func startupFallsBackToPersistedGeometry() throws {
        let display = SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        )
        let restored = try #require(
            resolver.resolvedStartupPrimaryWindowFrame(
                primaryFrame: nil,
                primaryDisplay: nil,
                fallbackFrame: CGRect(x: 180, y: 140, width: 900, height: 640),
                fallbackDisplay: SessionSourceDisplaySnapshot(
                    displayID: 1,
                    frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
                ),
                availableDisplays: [display],
                fallbackDisplay: display
            )
        )
        #expect(abs(restored.minX - 180) < 0.001)
        #expect(abs(restored.minY - 140) < 0.001)
        #expect(abs(restored.width - 900) < 0.001)
        #expect(abs(restored.height - 640) < 0.001)
    }

    @Test("startup primary frame prefers the primary snapshot over the fallback")
    func startupPrefersPrimarySnapshot() throws {
        let display = SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        )
        let restored = try #require(
            resolver.resolvedStartupPrimaryWindowFrame(
                primaryFrame: CGRect(x: 220, y: 160, width: 980, height: 700),
                primaryDisplay: SessionSourceDisplaySnapshot(
                    displayID: 1,
                    frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
                ),
                fallbackFrame: CGRect(x: 40, y: 30, width: 700, height: 500),
                fallbackDisplay: SessionSourceDisplaySnapshot(
                    displayID: 1,
                    frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
                ),
                availableDisplays: [display],
                fallbackDisplay: display
            )
        )
        #expect(abs(restored.minX - 220) < 0.001)
        #expect(abs(restored.minY - 160) < 0.001)
        #expect(abs(restored.width - 980) < 0.001)
        #expect(abs(restored.height - 700) < 0.001)
    }
}
