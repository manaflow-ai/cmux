import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Hover preload, live (plans/cmux-next/hover-preload-DESIGN.md): the pointer resting on a tab or a
/// workspace row wakes the pages that click would show, and a pointer that only passes wakes nothing.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct HoverWakeTests {
    typealias Rig = NeighborTabsWakeTests.Rig

    /// The pointer sweeps across three frozen far tabs at 120 Hz (one tab per 8 ms frame) and leaves the
    /// strip: no page thaws, none is kept awake, and nothing counts as prewarmed.
    @Test func aSweepAcrossTheStripWakesNothing() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let keys = try await rig.pages(["a", "b", "c", "d", "e", "f"])
        try await rig.until("every hidden page freezes") { keys.allSatisfy(rig.hibernation.frozen.contains) }
        rig.show(keys[0], order: keys) // b and f are neighbors and thaw
        let far = [keys[2], keys[3], keys[4]]
        let prewarmed = rig.hibernation.prewarmedCount

        for key in far {
            rig.hibernation.noteHover(key)
            try await Task.sleep(for: .milliseconds(8))
        }
        rig.hibernation.noteHover(nil)
        try await Task.sleep(for: .milliseconds(400))

        for key in far {
            #expect(rig.hibernation.frozen.contains(key), "a tab the pointer only crossed woke")
            #expect(rig.hibernation.exemptions[key] != .neighbor, "a tab the pointer only crossed is kept awake")
        }
        #expect(rig.hibernation.prewarmedCount == prewarmed)
    }
}
