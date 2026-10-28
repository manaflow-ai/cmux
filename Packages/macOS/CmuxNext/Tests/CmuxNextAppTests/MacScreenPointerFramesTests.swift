import AppKit
@testable import CmuxNextMacScreen
import CmuxNextWakeups
import Foundation
import Testing

/// A Mac Screen device tab sends its pointer on the windows' frames (feature `pointerFrameRemoteInput`):
/// the screen's input surface takes the app's coalescers when its view is made, so its
/// moves, drags and scrolls reach the host at most twice per frame; without them each goes at once.
@MainActor
struct MacScreenPointerFramesTests {
    private static let deviceID = "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff"

    private func makePages() -> MacScreenPages {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        return MacScreenPages(store: MacScreenStore(file: file, runner: BackgroundWork(label: "test.mac-screen")), deadlines: linklessDeadlines(), appEvents: AppEvents(center: NotificationCenter()))
    }

    @Test func aDeviceScreenTakesTheFramePointerInput() throws {
        let pages = makePages()
        let frames = FrameInputCoalescers()
        pages.pointerFrames = { frames }
        pages.prepare("a", record: MacScreenRecord(deviceID: Self.deviceID), byPerson: false)
        _ = pages.makeView(for: "a")
        let pane = try #require(pages.tab("a")?.pane)
        #expect(pane.view.input.pointerFrames === frames)
        pages.tabClosed("a")
    }

    @Test func withoutTheFeatureADeviceScreenSendsEachEvent() throws {
        let pages = makePages()
        pages.prepare("b", record: MacScreenRecord(deviceID: Self.deviceID), byPerson: false)
        _ = pages.makeView(for: "b")
        let pane = try #require(pages.tab("b")?.pane)
        #expect(pane.view.input.pointerFrames == nil)
        pages.tabClosed("b")
    }
}
