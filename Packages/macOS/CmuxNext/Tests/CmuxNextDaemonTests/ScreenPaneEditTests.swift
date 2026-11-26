@testable import CmuxNextDaemon
import CmuxNextCompat
import Observation
import Testing

/// A pane added to or taken from a screen is one in-place edit (``ScreenModel/insertPane(_:at:)``,
/// ``ScreenModel/removePane(_:)``): the `panes` setter copied the list and re-adopted and recounted every pane, so a
/// split's provisional pane cost O(panes) (overlay bench, 256 panes: 62 µs of a 257 µs intend). The edit keeps the
/// order, each pane's screen and the screen's unread tally equal to a recount of all panes.
@MainActor @Suite struct ScreenPaneEditTests {
    private static func pane(_ id: UInt64, unread: Bool = false) -> PaneSnapshot {
        PaneSnapshot(id: PaneID(rawValue: id),
                     tabs: [TabSnapshot(surface: SurfaceID(rawValue: id * 10),
                                        notification: unread ? TabNotification(notification: NotificationID(rawValue: id), unread: true) : nil)])
    }

    private static func screen(_ count: Int) -> ScreenModel {
        ScreenModel(ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)),
                                   panes: (1...UInt64(count)).map { pane($0, unread: $0 % 3 == 0) }))
    }

    /// The tally a full recount gives.
    private static func recounted(_ screen: ScreenModel) -> UnreadTally {
        var tally = UnreadTally()
        for pane in screen.panes { tally.add(pane.unread) }
        return tally
    }

    @Test func insertKeepsOrderOwnerAndUnreadTally() {
        let screen = Self.screen(64)
        let unread = PaneModel(Self.pane(1000, unread: true))
        let quiet = PaneModel(Self.pane(1001))
        screen.insertPane(unread, at: 10)
        screen.insertPane(quiet, at: 500)
        #expect(screen.panes[10] === unread)
        #expect(screen.panes.last === quiet, "an index past the end is clamped to the end")
        #expect(screen.panes.count == 66)
        #expect(unread.unreadScreen === screen && quiet.unreadScreen === screen)
        #expect(screen.unread == Self.recounted(screen))
        #expect(screen.unread.tabs == 22)
    }

    @Test func removeKeepsOrderAndUnreadTally() {
        let screen = Self.screen(64)
        let before = screen.panes.map(\.handle)
        let unread = screen.panes[2], quiet = screen.panes[3]
        screen.removePane(unread)
        screen.removePane(quiet)
        screen.removePane(quiet)
        #expect(screen.panes.map(\.handle) == before.filter { $0 != unread.handle && $0 != quiet.handle })
        #expect(screen.unread == Self.recounted(screen))
        #expect(screen.unread.tabs == 20)
    }

    /// A held tree (the overlay lift) publishes the net pane change once, as the setter did.
    @Test func heldTreePublishesTheInsertOnce() {
        let screen = Self.screen(4)
        let pane = PaneModel(Self.pane(9))
        screen.holdTree()
        screen.insertPane(pane, at: 0)
        screen.removePane(pane)
        let changed = PaneListHeard()
        withObservationTracking { _ = screen.panes } onChange: { changed.set() }
        screen.publishHeldTree()
        #expect(!changed.value, "an insert and remove inside one hold publish nothing")
    }
}

/// An observer's onChange ran (it may run on any thread).
private final class PaneListHeard: Sendable {
    private let heard = Mutex(false)
    nonisolated deinit {}
    var value: Bool { heard.withLock { $0 } }
    func set() { heard.withLock { $0 = true } }
}
