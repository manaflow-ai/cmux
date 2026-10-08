import AppKit
import Testing
@testable import MessagesLabSidebar

/// A host that also takes a drop position (cmux's Home sidebar): the list asks, the host
/// changes its order and reloads in the same turn.
@MainActor
final class OrderingHost: SidebarDataSource, SidebarDelegate, SidebarPinPlacing {
    let base: PinningHost
    var placed: [(ConversationID, Int)] = []
    var unpinned: [ConversationID] = []

    init(count: Int, pinned: [ConversationID]) {
        base = PinningHost(count: count)
        base.pinned = pinned
    }

    func sidebarSnapshot(_ sidebar: SidebarController) -> ConversationListSnapshot { base.sidebarSnapshot(sidebar) }
    func sidebar(_ sidebar: SidebarController, didSelect id: ConversationID?) {}
    func sidebar(_ sidebar: SidebarController, setPinned on: Bool, for id: ConversationID) {
        if !on { unpinned.append(id) }
        base.sidebar(sidebar, setPinned: on, for: id)
    }
    func sidebar(_ sidebar: SidebarController, place id: ConversationID, at index: Int) {
        placed.append((id, index))
        var order = base.pinned.filter { $0 != id }
        order.insert(id, at: min(index, order.count))
        base.pinned = order
        sidebar.reloadData()
    }
}

/// Messages' pinned grid reorders by drag: press a tile and drag it, the others make room,
/// the drop places it; a tile dragged out of the grid is unpinned, a row dragged into the
/// grid is pinned at the drop position, and Escape puts everything back.
@MainActor @Suite(.serialized) struct SidebarPinDragTests {
    // The order model alone.

    @Test func movingTheFirstTileToTheEnd() {
        var drag = SidebarPinDrag(id: "a", source: .tile, pinned: ["a", "b", "c", "d"])
        drag.target = 3
        #expect(drag.order == ["b", "c", "d", "a"])
        #expect(drag.outcome == .place("a", 3))
    }

    @Test func movingTheLastTileToTheFront() {
        var drag = SidebarPinDrag(id: "d", source: .tile, pinned: ["a", "b", "c", "d"])
        drag.target = 0
        #expect(drag.order == ["d", "a", "b", "c"])
        #expect(drag.outcome == .place("d", 0))
    }

    @Test func movingAMiddleTile() {
        var drag = SidebarPinDrag(id: "b", source: .tile, pinned: ["a", "b", "c", "d"])
        drag.target = 2
        #expect(drag.order == ["a", "c", "b", "d"])
        #expect(drag.outcome == .place("b", 2))
        drag.target = 1
        #expect(drag.outcome == .none, "dropped where it started: nothing changes")
    }

    @Test func cancellingRestoresTheOrder() {
        var drag = SidebarPinDrag(id: "a", source: .tile, pinned: ["a", "b", "c"])
        drag.target = 2
        drag.cancel()
        #expect(drag.order == ["a", "b", "c"])
        #expect(drag.outcome == .none)
    }

    @Test func aTileOutsideTheGridUnpinsAndARowInsideItPins() {
        var tile = SidebarPinDrag(id: "b", source: .tile, pinned: ["a", "b", "c"])
        tile.target = nil
        #expect(tile.order == ["a", "c"])
        #expect(tile.outcome == .unpin("b"))
        var row = SidebarPinDrag(id: "x", source: .row, pinned: ["a", "b"])
        #expect(row.outcome == .none, "a row that never reached the grid stays a row")
        row.target = 1
        #expect(row.order == ["a", "x", "b"])
        #expect(row.outcome == .place("x", 1))
    }

    // The list, driven the way the pointer does.

    static func sidebar(_ host: OrderingHost) -> SidebarController {
        let sidebar = SidebarController()
        sidebar.dataSource = host
        sidebar.delegate = host
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 320, height: 700)
        sidebar.view.layoutSubtreeIfNeeded()
        sidebar.reloadData()
        return sidebar
    }

    static func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    static func tileIDs(_ sidebar: SidebarController) -> [ConversationID] { sidebar.pinnedItems.map { sidebar.snapshot.items[$0].id } }

    @Test func draggingATileToTheLastSlotPlacesItThere() {
        let host = OrderingHost(count: 8, pinned: ["c0", "c1", "c2", "c3"])
        let sidebar = Self.sidebar(host)
        #expect(sidebar.beginPinDrag(at: Self.center(sidebar.tileRect(0))))
        sidebar.movePinDrag(to: Self.center(sidebar.tileRect(3)))
        #expect(sidebar.pinDragOrder == ["c1", "c2", "c3", "c0"], "the other tiles make room")
        sidebar.endPinDrag()
        #expect(host.placed.map(\.0) == ["c0"] && host.placed.map(\.1) == [3])
        #expect(Self.tileIDs(sidebar) == ["c1", "c2", "c3", "c0"])
        #expect(sidebar.pinDragOrder == nil)
    }

    @Test func escapeCancelsADrag() {
        let host = OrderingHost(count: 8, pinned: ["c0", "c1", "c2"])
        let sidebar = Self.sidebar(host)
        #expect(sidebar.beginPinDrag(at: Self.center(sidebar.tileRect(2))))
        sidebar.movePinDrag(to: Self.center(sidebar.tileRect(0)))
        #expect(sidebar.pinDragOrder == ["c2", "c0", "c1"])
        sidebar.cancelPinDrag()
        #expect(host.placed.isEmpty && host.unpinned.isEmpty)
        #expect(Self.tileIDs(sidebar) == ["c0", "c1", "c2"])
        #expect(sidebar.tileLayers.allSatisfy { !$0.isHidden })
        for t in sidebar.tileLayers.indices { #expect(sidebar.tileLayers[t].frame == sidebar.tileRect(t), "every tile back in its slot") }
    }

    @Test func draggingATileOntoTheListUnpinsIt() {
        let host = OrderingHost(count: 8, pinned: ["c0", "c1", "c2"])
        let sidebar = Self.sidebar(host)
        #expect(sidebar.beginPinDrag(at: Self.center(sidebar.tileRect(1))))
        sidebar.movePinDrag(to: Self.center(sidebar.rowRect(3)))
        #expect(sidebar.pinDragOrder == ["c0", "c2"])
        sidebar.endPinDrag()
        #expect(host.unpinned == ["c1"] && host.placed.isEmpty)
        #expect(Self.tileIDs(sidebar) == ["c0", "c2"])
    }

    @Test func draggingARowIntoTheGridPinsItAtTheDropPosition() {
        let host = OrderingHost(count: 8, pinned: ["c0", "c1"])
        let sidebar = Self.sidebar(host)
        let row = sidebar.rowItems.firstIndex { sidebar.snapshot.items[$0].id == "c5" }!
        #expect(sidebar.beginPinDrag(at: Self.center(sidebar.rowRect(row))))
        sidebar.movePinDrag(to: Self.center(sidebar.tileRect(1)))
        #expect(sidebar.pinDragOrder == ["c0", "c5", "c1"])
        sidebar.endPinDrag()
        #expect(host.placed.map(\.0) == ["c5"] && host.placed.map(\.1) == [1])
        #expect(Self.tileIDs(sidebar) == ["c0", "c5", "c1"])
    }

    @Test func aRowDroppedBackOnTheListChangesNothing() {
        let host = OrderingHost(count: 8, pinned: ["c0"])
        let sidebar = Self.sidebar(host)
        #expect(sidebar.beginPinDrag(at: Self.center(sidebar.rowRect(2))))
        sidebar.movePinDrag(to: Self.center(sidebar.rowRect(4)))
        sidebar.endPinDrag()
        #expect(host.placed.isEmpty && host.unpinned.isEmpty)
        #expect(Self.tileIDs(sidebar) == ["c0"])
    }
}
