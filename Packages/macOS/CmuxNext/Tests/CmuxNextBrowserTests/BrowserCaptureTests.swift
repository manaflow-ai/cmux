@testable import CmuxNextBrowser
import Foundation
import Testing

/// Lawrence 2026-10-28 (u14806): "a browser tab has a camera/microphone thing but idk which
/// tab/workspace it is". The engines' capture reports reach the tab's state
/// (``BrowserTabState/capture``), the source of the tab's and the row's red mark, of Page
/// Info's "in use", of the hibernation guard and of Stop and Block.
@MainActor @Suite struct BrowserCaptureTests {
    /// Chromium's `OnMediaAccessChange` (MEDIA_ACCESS, kind 51): bit 1 camera, bit 2 microphone.
    @Test(arguments: [(Int64(0), 0), (1, 1), (2, 2), (3, 3)])
    func chromiumsReportDecodes(_ bits: Int64, _ raw: Int) {
        let capture = BrowserCapture(rawValue: raw)
        #expect(CEFShimEvent(kind: 51, browser: 7, request: 0, a: bits, b: 0, s1: "", s2: "")
            == .mediaAccess(browser: 7, capture: capture))
        #expect(CEFShimEvent(kind: 51, browser: 7, request: 0, a: bits, b: 0, s1: "", s2: "").browserID == 7)
    }

    /// The report sets the state; a renderer that ends ends its capture.
    @Test func theStateFollowsTheReportAndAGonePageCapturesNothing() {
        var machine = BrowserTabStateMachine()
        machine.apply(.captureChanged([.camera, .microphone]))
        #expect(machine.state.capture == [.camera, .microphone])
        #expect(machine.state.capture.sitePermissionKinds == [.camera, .microphone])
        machine.apply(.captureChanged(.microphone))
        #expect(machine.state.capture == .microphone)
        machine.apply(.processExited(BrowserProcessExit(reason: .crashed)))
        #expect(machine.state.capture.isEmpty)
    }

    /// Stop ends the capture and keeps the site's permission; Block also stores Page Info's Block
    /// for camera and microphone on the page's site.
    @Test func stopEndsTheCaptureAndBlockAlsoRevokesTheSite() async throws {
        let engine = MockBrowserEngine(kind: .cef)
        let tab = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://call.example.com/room")))
        tab.simulate(.urlChanged(URL(string: "https://call.example.com/room")))
        tab.simulate(.captureChanged([.camera, .microphone]))
        tab.stopCapture()
        #expect(tab.state.capture.isEmpty)
        #expect(tab.commands.contains(.stopCapture))
        let store = tab.pageInfoSettings.permissions(for: tab.profileID)
        #expect(store.decision(.camera, for: "https://call.example.com") == nil)

        tab.simulate(.captureChanged(.microphone))
        tab.blockCapture()
        #expect(tab.state.capture.isEmpty)
        #expect(store.decision(.camera, for: "https://call.example.com") == .block)
        #expect(store.decision(.microphone, for: "https://call.example.com") == .block)
    }
}
