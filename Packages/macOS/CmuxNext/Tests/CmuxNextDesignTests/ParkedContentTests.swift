import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Offender 4 of the 2026-10-21 GPU audit: hiding a parked workspace costs WindowServer about 30 ms per
/// pane on each switch back. A workspace can instead stay unhidden and parked (`ParkingContainer`);
/// the views below must stop drawing and hear the change, and hidden parking must walk nothing.
@MainActor @Suite(.closesItsWindows) struct ParkedContentTests {
    final class Container: NSView, ParkingContainer {
        var isParkedOffScreen = false
    }

    final class Observer: NSView, ParkingObserver {
        var changes = 0
        func parkingDidChange() { changes += 1 }
    }

    private func window(with view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = view
        return window
    }

    @Test func aViewUnderAParkedContainerDoesNotDraw() {
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let container = Container(), leaf = NSView()
        container.addSubview(leaf)
        let host = window(with: container)
        defer { host.closeAfterTest() }
        #expect(WindowDrawPolicy.inputs(for: leaf, suspended: false).draws)
        container.isParkedOffScreen = true
        #expect(leaf.isParkedOrHasParkedAncestor)
        #expect(WindowDrawPolicy.inputs(for: leaf, suspended: false).pause == .parked)
        // Hidden wins: the hidden path reports as it did.
        container.isHidden = true
        #expect(WindowDrawPolicy.inputs(for: leaf, suspended: false).pause == .hidden)
        _ = host
    }

    @Test func theWalkReachesObserversAndSkipsHiddenSubtrees() {
        let container = Container(), shown = Observer(), hiddenBranch = NSView(), underHidden = Observer()
        container.addSubview(shown)
        container.addSubview(hiddenBranch)
        hiddenBranch.addSubview(underHidden)
        hiddenBranch.isHidden = true
        container.notifyParkingChange()
        #expect(shown.changes == 1)
        #expect(underHidden.changes == 0)
        // A hidden container (hidden parking) walks nothing.
        container.isHidden = true
        container.notifyParkingChange()
        #expect(shown.changes == 1)
    }
}
