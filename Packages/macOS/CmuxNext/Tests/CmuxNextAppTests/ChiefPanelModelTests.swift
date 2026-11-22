import CmuxNextLayout
import CoreGraphics
import Testing

/// ``ChiefPanel`` and ``ChiefPanelFrame``: the rules of the window's Chief panel as a pure value (user 2026-11-06).
@Suite struct ChiefPanelModelTests {
    /// Closed by default; open, it shows over any workspace but Home; hidden, it keeps its placement.
    @Test func itShowsOnlyWhenOpenAndNeverOverHome() {
        var panel = ChiefPanel()
        #expect(!panel.isShown(stage: "ws", home: "home"), "a new window shows the Chief")
        panel.open()
        #expect(panel.isShown(stage: "ws", home: "home"))
        #expect(!panel.isShown(stage: "home", home: "home"), "the Chief shows over Home")
        #expect(!panel.isShown(stage: nil, home: "home"))
        panel.dock(at: .right)
        #expect(!panel.isShown(stage: "home", home: "home"), "the docked Chief shows over Home")
        panel.hide()
        #expect(!panel.isShown(stage: "ws", home: "home"))
        #expect(panel.dockedEdge == .right, "hiding lost the dock")
        let undocked = panel.undock()
        #expect(undocked && panel.dockedEdge == nil)
        let again = panel.undock()
        #expect(!again, "a floating panel undocked again")
    }

    /// Docked, the panel takes its extent at its edge and the stage the rest; floating, the stage keeps everything.
    @Test(arguments: [DockEdge.left, .right, .top, .bottom])
    func dockedItTakesItsEdge(_ edge: DockEdge) {
        var panel = ChiefPanel()
        panel.dock(at: edge)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let (rect, stage) = panel.split(bounds)
        #expect(!rect.intersects(stage), "\(edge): the Chief covers the stage")
        #expect(rect.union(stage) == bounds, "\(edge): the Chief and the stage leave a gap")
        switch edge {
        case .left: #expect(rect.minX == 0 && rect.width == 300)
        case .right: #expect(rect.maxX == 1000 && rect.width == 300)
        case .top: #expect(rect.minY == 0 && rect.height == 180) // y runs down
        case .bottom: #expect(rect.maxY == 600 && rect.height == 180)
        }
        panel.placement = .floating
        #expect(panel.split(bounds).stage == bounds)
    }

    /// The floating place stays inside the content area at any window size, at least the minimum size, and a drop
    /// stores the place that gives that rect back.
    @Test func theFloatingPlaceStaysInsideAndRoundTrips() {
        let size = CGSize(width: 1000, height: 600)
        let drop = CGRect(x: 120, y: 80, width: 400, height: 300)
        let frame = ChiefPanelFrame.fitting(drop, in: size)
        #expect(frame.rect(in: size) == drop)
        let small = CGSize(width: 500, height: 300)
        let r = frame.rect(in: small)
        #expect(CGRect(origin: .zero, size: small).contains(r), "off the smaller area: \(r)")
        #expect(r.width >= ChiefPanelFrame.minimumSize.width && r.height >= ChiefPanelFrame.minimumSize.height)
        let off = ChiefPanelFrame.fitting(CGRect(x: 900, y: 550, width: 400, height: 300), in: size).rect(in: size)
        #expect(CGRect(origin: .zero, size: size).contains(off), "a drop past the corner left it off the area: \(off)")
    }
}
