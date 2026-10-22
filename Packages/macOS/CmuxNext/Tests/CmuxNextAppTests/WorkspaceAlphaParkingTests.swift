import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// Offender 4 of the 2026-10-21 GPU audit: hiding the workspace a switch leaves costs WindowServer
/// about 30 ms per pane on the switch back. Debug Settings `workspace.parkByAlpha` (off by default)
/// parks it unhidden at alpha 0 instead; the parked signal stops its subtree, and hidden parking stays
/// as it was while the toggle is off.
@MainActor @Suite(.serialized) struct WorkspaceAlphaParkingTests {
    typealias F = WorkspaceSwitchRedrawHoldTests

    static func withAlphaParking<T>(_ on: Bool, _ body: () throws -> T) rethrows -> T {
        TunableStore.shared.register(WorkspaceParkingTunables.all)
        TunableStore.shared.activate(file: nil)
        let before = TunableStore.shared.override(WorkspaceParkingTunables.parkByAlpha.key)
        TunableStore.shared.set(WorkspaceParkingTunables.parkByAlpha.key, on ? .bool(true) : nil)
        precondition(WorkspaceParkingTunables.parkByAlpha.value == on, "the workspace.parkByAlpha override did not take")
        defer { TunableStore.shared.set(WorkspaceParkingTunables.parkByAlpha.key, before) }
        return try body()
    }

    /// A view in the workspace that stops work while parked (as terminals and the layout do).
    final class Worker: NSView, ParkingObserver {
        private(set) var parked = false
        func parkingDidChange() { parked = isParkedOrHasParkedAncestor }
    }

    private static func center(of view: NSView) -> NSPoint { NSPoint(x: view.frame.midX, y: view.frame.midY) }

    @Test func offByDefaultASwitchHidesTheWorkspaceItLeaves() {
        Self.withAlphaParking(false) {
            let (window, root) = F.root()
            defer { window.close() }
            let a = F.workspace(Worker()), b = F.workspace(Worker())
            F.show(a, in: root)
            F.show(b, in: root)
            #expect(a.isHidden)
            #expect(a.isParkedOffScreen)
            #expect(a.alphaValue == 1)
            F.show(a, in: root)
            #expect(!a.isHidden)
            #expect(!a.isParkedOffScreen)
            #expect(b.isHidden)
        }
    }

    @Test func onASwitchParksTheWorkspaceUnhiddenAndStopsItsSubtree() throws {
        try Self.withAlphaParking(true) {
            let (window, root) = F.root()
            defer { window.close() }
            let worker = Worker()
            let a = F.workspace(worker), b = F.workspace(Worker())
            F.show(a, in: root)
            F.show(b, in: root)
            #expect(!a.isHidden)
            #expect(a.alphaValue == 0)
            #expect(a.isParkedOffScreen)
            #expect(worker.parked)
            #expect(a.hitTest(Self.center(of: a)) == nil)
            #expect(try #require(a.accessibilityChildren()).isEmpty)
            F.show(a, in: root)
            #expect(a.alphaValue == 1)
            #expect(!a.isParkedOffScreen)
            #expect(!worker.parked)
            #expect(b.alphaValue == 0)
            #expect(b.isParkedOffScreen)
        }
    }

    @Test func aPageWindowHidesTheWorkspacesParkedByAlpha() {
        Self.withAlphaParking(true) {
            let (window, root) = F.root()
            defer { window.close() }
            let a = F.workspace(Worker()), b = F.workspace(Worker())
            F.show(a, in: root)
            F.show(b, in: root)
            #expect(a.alphaValue == 0)
            // A Chromium page conceals only when its view is hidden.
            root.hideAlphaParkedWorkspaces()
            #expect(a.isHidden)
            #expect(a.isParkedOffScreen)
            #expect(!b.isHidden)
            F.show(a, in: root)
            #expect(!a.isHidden)
            #expect(a.alphaValue == 1)
            #expect(!a.isParkedOffScreen)
        }
    }

    /// A switch that waits for pages to redraw hands off to a newer one: the hand-off makes the view it
    /// takes away opaque, which must not show a workspace parked at alpha 0.
    @Test func aWorkspaceParkedByAHandOffStaysUnseen() {
        Self.withAlphaParking(true) {
            let (window, root) = F.root()
            defer { window.close() }
            let a = F.workspace(F.DrawnPage()), b = F.workspace(F.DrawnPage()), c = F.workspace(F.DrawnPage())
            F.show(a, in: root)
            F.show(b, in: root)
            F.show(c, in: root)
            window.setContentSize(NSSize(width: 1240, height: 700))
            root.layoutSubtreeIfNeeded()
            root.show(a)
            #expect(a.alphaValue == 0, "A waits for its page to draw at the new size")
            root.show(b)
            #expect(!a.isHidden)
            #expect(a.isParkedOffScreen)
            #expect(a.alphaValue == 0)
        }
    }
}
