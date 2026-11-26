#if os(iOS)
import CmuxDeviceHub
import CmuxMobileBrowserStream
import Foundation
import Testing
@testable import CmuxMobileScreenSharing

/// Mac Screen over Link: Screen Sharing shows a Mac on its cmux-wg link (`surface` `d~0`, view
/// only) only when Settings → Transport → Mac Screen over Link is on and that Mac lists
/// `mac-display-v1`; otherwise, and when the link stream fails, the device hub's WebRTC path.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ScreenSharingLinkTests {
    typealias Route = ScreenSharingLinkRoute

    private func linked(_ name: String = "Studio", id: String = "mac-1",
                        capabilities: Set<String>? = ["surface-stream-v1", "mac-display-v1"]) -> ScreenSharingLinkedMac {
        ScreenSharingLinkedMac(macID: id, name: name, capabilities: capabilities)
    }

    @Test func theCapabilityAndTabMatchTheMacsHost() {
        // hostd's names.rs MAC_DISPLAY and surface.rs mac_display_of("d~0").
        #expect(Route.capability == "mac-display-v1")
        #expect(Route.mainDisplayTab == "d~0")
        #expect(Route.streamsDisplay(["cloud-desktop-v1", "mac-display-v1"]))
        #expect(!Route.streamsDisplay(["cloud-desktop-v1", "surface-stream-v1"]))
        #expect(!Route.streamsDisplay(nil))
    }

    @Test func theLinkIsUsedOnlyWithTheSettingOnAndTheCapability() {
        #expect(Route.linkMac(named: "Studio", settingOn: true, linked: [linked()]) == "mac-1")
        // Off by default: the WebRTC path, whatever the Mac offers.
        #expect(Route.linkMac(named: "Studio", settingOn: false, linked: [linked()]) == nil)
        // A Mac whose host does not capture its displays, or whose `version` is not known yet.
        #expect(Route.linkMac(named: "Studio", settingOn: true, linked: [linked(capabilities: ["cloud-desktop-v1"])]) == nil)
        #expect(Route.linkMac(named: "Studio", settingOn: true, linked: [linked(capabilities: nil)]) == nil)
        // Not linked, or two linked Macs by that name: the hub decides.
        #expect(Route.linkMac(named: "Studio", settingOn: true, linked: []) == nil)
        #expect(Route.linkMac(named: "Studio", settingOn: true, linked: [linked(), linked(id: "mac-2")]) == nil)
        // The hub and the link name a Mac alike (case and apostrophes folded).
        #expect(Route.linkMac(named: "Aziz\u{2019}s Mac", settingOn: true, linked: [linked("aziz's mac")]) == "mac-1")
    }

    @Test func theSettingIsOffByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        #expect(!Route.settingOn(defaults))
        defaults.set(true, forKey: "cmuxMobile.settings.macScreenOverLink")
        #expect(Route.settingOn(defaults))
    }

    @Test func withTheSettingOnTheMacOpensOnItsLinkViewOnly() {
        let (service, _) = ScreenSharingViewerTests().makeService()
        var opened: [String] = []
        service.linkSetting = { true }
        service.linkedMacs = { [self] in [linked()] }
        service.openMacDisplay = { macID, _ in
            opened.append(macID)
            return Self.stream()
        }
        let mac = HubDevice(id: "hub-mac", name: "Studio", platform: .macos, signingKey: "", macScreenShared: true, online: true)
        #expect(service.connect(to: mac, scope: .full) == nil)
        #expect(opened == ["mac-1"])
        #expect(service.linkViewer?.stream.tab == "d~0")
        #expect(service.viewer == nil)
        if case .link? = service.screenOnScreen {} else { Issue.record("the link screen is not on screen") }
        service.dismissViewer()
        #expect(service.linkViewer == nil)
    }

    @Test func withTheSettingOffTheHubPathIsUntouched() {
        let (service, _) = ScreenSharingViewerTests().makeService()
        var opened = 0
        service.linkSetting = { false }
        service.linkedMacs = { [self] in [linked()] }
        service.openMacDisplay = { _, _ in
            opened += 1
            return Self.stream()
        }
        let mac = HubDevice(id: "hub-mac", name: "Studio", platform: .macos, signingKey: "", macScreenShared: true, online: true)
        let viewer = service.connect(to: mac, scope: .full)
        #expect(opened == 0)
        #expect(service.linkViewer == nil)
        #expect(viewer?.phase == .requesting(.full))
        service.dismissViewer()
    }

    @Test func aFailedLinkStreamFallsBackToWebRTC() async {
        let (service, ends) = ScreenSharingViewerTests().makeService()
        var refuse: (@MainActor @Sendable (String) -> Void)?
        service.linkSetting = { true }
        service.linkedMacs = { [self] in [linked()] }
        service.openMacDisplay = { _, refused in
            refuse = refused
            return Self.stream()
        }
        let mac = HubDevice(id: "hub-mac", name: "Studio", platform: .macos, signingKey: "", macScreenShared: true, online: true)
        service.connect(to: mac, scope: .view)
        #expect(service.linkViewer != nil)
        // Share This Mac went off on the Mac: hostd refuses the open (`unavailable`).
        refuse?("unavailable")
        #expect(service.linkViewer == nil)
        #expect(service.viewer?.hostID == "hub-mac")
        #expect(service.viewer?.phase == .requesting(.view))
        await ends.waitForRequest()
        // A late refusal of the old stream changes nothing.
        refuse?("closed")
        #expect(service.viewer?.phase == .requesting(.view))
        service.dismissViewer()
    }

    @Test func noPictureInTimeFallsBackToWebRTC() async {
        let (service, ends) = ScreenSharingViewerTests().makeService()
        service.linkSetting = { true }
        service.linkedMacs = { [self] in [linked()] }
        service.openMacDisplay = { _, _ in Self.stream() }
        let mac = HubDevice(id: "hub-mac", name: "Studio", platform: .macos, signingKey: "", macScreenShared: true, online: true)
        service.connect(to: mac, scope: .full)
        let link = service.linkViewer
        link?.firstFrameDeadline = .milliseconds(10)
        link?.startDeadline()
        await ends.waitForRequest()
        #expect(service.linkViewer == nil)
        #expect(link?.failure == "no_picture")
        #expect(service.viewer?.phase == .requesting(.full))
        service.dismissViewer()
    }

    @Test func aClosedLinkScreenNeverFallsBack() {
        let (service, _) = ScreenSharingViewerTests().makeService()
        var refuse: (@MainActor @Sendable (String) -> Void)?
        service.linkSetting = { true }
        service.linkedMacs = { [self] in [linked()] }
        service.openMacDisplay = { _, refused in
            refuse = refused
            return Self.stream()
        }
        let mac = HubDevice(id: "hub-mac", name: "Studio", platform: .macos, signingKey: "", macScreenShared: true, online: true)
        service.connect(to: mac, scope: .full)
        service.dismissViewer()
        // Closing the stream ends it with a close code: the person closed it, nothing reconnects.
        refuse?("closed")
        #expect(service.linkViewer == nil)
        #expect(service.viewer == nil)
    }

    private static func stream() -> StreamedBrowserModel {
        StreamedBrowserModel(tab: Route.mainDisplayTab, url: nil) { _ in
            throw CancellationError()
        }
    }
}
#endif
