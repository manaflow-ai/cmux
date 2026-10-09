import AppKit
import Testing
@testable import MessagesLabSidebar

/// Crash program (index_subscript / int_conversion): stale hits and tile indices from a
/// previous list, and NaN or huge geometry, refuse or clamp instead of trapping.
@MainActor @Suite(.serialized) struct SidebarIndexFuzzTests {
    private static func sidebar(count: Int) -> (SidebarController, PinningHost) {
        let host = PinningHost(count: count)
        let sidebar = SidebarController()
        sidebar.dataSource = host
        sidebar.delegate = host
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 320, height: 700)
        sidebar.reloadData()
        return (sidebar, host)
    }

    @Test func aStaleTileIndexGivesAnEmptyGeometry() {
        let (sidebar, _) = Self.sidebar(count: 4)
        let g = sidebar.tileGeometry(7)
        #expect(g.bounds == .zero)
    }

    @Test func aHitFromABiggerListNamesNoConversation() {
        let (sidebar, host) = Self.sidebar(count: 12)
        sidebar.setPinned(true, "c1")
        let staleRow = SidebarController.Hit.row(11), staleTile = SidebarController.Hit.tile(0)
        host.pinned = []
        host.items = Array(host.items.prefix(2))
        sidebar.reloadData()
        _ = sidebar.item(staleRow)
        _ = sidebar.item(staleTile)
        sidebar.moveSelection(5)
        sidebar.moveSelection(-9)
    }

    @Test func nonFiniteGeometryDoesNotTrap() throws {
        for w in [CGFloat.nan, .infinity, -.infinity, 1e300, -5, 0] {
            _ = SidebarMetrics(width: w).columns
        }
        let appearance = try #require(NSAppearance(named: .darkAqua))
        let ctx = SidebarRenderContext(metrics: SidebarMetrics(width: 320), palette: SidebarPalette.resolve(appearance), scale: 2,
                                       space: CGColorSpaceCreateDeviceRGB(), generation: 0, bellSecondary: nil, bellSelected: nil,
                                       now: Date())
        for side in [CGFloat.nan, .infinity, 1e300] {
            _ = SidebarDraw.bitmap(size: CGSize(width: side, height: 4), ctx: ctx) { _ in }
        }
    }

    @Test func randomListsAndPointsDoNotTrap() {
        var seed: UInt64 = 0xC0FFEE
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(truncatingIfNeeded: (seed >> 33) % UInt64(max(1, n))) }
        let (sidebar, host) = Self.sidebar(count: 30)
        for _ in 0..<80 {
            host.items = Array(PinningHost(count: 30).items.prefix(next(31)))
            host.pinned = host.items.prefix(next(5)).map(\.id)
            sidebar.view.frame = NSRect(x: 0, y: 0, width: CGFloat(60 + next(400)), height: CGFloat(1 + next(900)))
            sidebar.reloadData()
            for _ in 0..<6 {
                let p = CGPoint(x: CGFloat(next(500)) - 20, y: CGFloat(next(3000)) - 50)
                if let h = sidebar.hit(p) { _ = sidebar.item(h); _ = sidebar.rect(h) }
                sidebar.mouseMoved(p)
                _ = sidebar.menu(at: p)
            }
            sidebar.moveSelection(next(7) - 3)
            _ = sidebar.accessibilityElements()
        }
    }
}
