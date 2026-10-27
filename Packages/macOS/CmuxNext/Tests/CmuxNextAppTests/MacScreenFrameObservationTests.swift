import AppKit
import CmuxNextWakeups
@testable import CmuxNextMacScreen
import CmuxScreenKit
import Foundation
import Testing

/// Mac Screen's chrome follows its model through FrameObservation (plans/cmux-next/chrome-parity/
/// p04-input.md, task 028), not one main-actor task per change: a burst of changes applies once,
/// and a hidden tab applies nothing until it shows, then reads once. The stream's phase is the one
/// node-free watch: the hub hears a hidden tab's failed stream during its grace.
@MainActor @Suite(.serialized)
struct MacScreenFrameObservationTests {
    private func pane(on node: VisibilityNode, _ work: MainWorkScheduler) -> MacScreenPane {
        MacScreenPane(hubDevice: MacScreenHubViewer(deviceID: "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff") { nil }, name: "Studio",
                      preferences: ScreenPreferences(), node: node, on: work)
    }

    private func texts(under root: NSView) -> [String] {
        root.subviews.flatMap { view in [(view as? NSTextField)?.stringValue].compactMap { $0 } + texts(under: view) }
    }

    private func entry(_ owner: String, in work: MainWorkScheduler) throws -> ObservationLedger.Entry {
        try #require(work.observations.snapshot(matching: owner).first, "no observation named \(owner)")
    }

    @Test func aBurstOfChangesAppliesOnceAfterItsTurn() throws {
        let work = linklessMainWork()
        let pane = pane(on: shownNode(), work)
        let toolbar = pane.view.chrome.toolbar
        for index in 1...50 { pane.model.name = "Studio \(index)" }
        #expect(!texts(under: toolbar).contains("Studio 50"), "the toolbar applied inside the changes' own turn")
        #expect(runMainLoop { texts(under: toolbar).contains("Studio 50") })
        #expect(try entry("mac-screen.toolbar", in: work).applies == 1, "50 name changes applied more than once")
        #expect(try entry("mac-screen.card", in: work).applies == 1, "the Connect card rebuilt more than once")
        pane.close()
    }

    @Test func aHiddenTabAppliesNothingUntilItShows() throws {
        let work = linklessMainWork()
        let node = VisibilityNode(root: "test.tab", own: .hidden)
        let pane = pane(on: node, work)
        let toolbar = pane.view.chrome.toolbar
        for index in 1...50 { pane.model.name = "Studio \(index)" }
        for _ in 0..<5 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        #expect(texts(under: toolbar).contains("Studio"), "a hidden tab's toolbar changed")
        #expect(try entry("mac-screen.toolbar", in: work).evaluations == 0, "a hidden tab's toolbar read its model")
        node.set(.visible)
        #expect(texts(under: toolbar).contains("Studio 50"), "the shown tab did not read its model once at the show")
        #expect(try entry("mac-screen.toolbar", in: work).showRereads == 1)
        pane.close()
    }

    @Test func aHiddenTabsHubHearsItsStreamFail() throws {
        let work = linklessMainWork()
        let node = VisibilityNode(root: "test.tab", own: .hidden)
        let viewer = MacScreenHubViewer(deviceID: "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff") { nil }
        viewer.endSession = { _, _, _ in }
        let pane = MacScreenPane(hubDevice: viewer, name: "Studio", preferences: ScreenPreferences(), node: node, on: work)
        viewer.phase = .streaming(sessionID: "s1", scope: .full)
        let session = try #require(pane.session)
        // The viewer holds no ticket's signaling: the connect fails at once.
        session.connect()
        #expect(runMainLoop { viewer.phase == .streamFailed(sessionID: "s1", scope: .full) },
                "the hub did not hear the hidden tab's stream fail (\(viewer.phase))")
        #expect(!node.isVisible, "the tab showed during the test")
        #expect(try entry("mac-screen.pane.phase", in: work).applies >= 1)
        pane.close()
    }
}
