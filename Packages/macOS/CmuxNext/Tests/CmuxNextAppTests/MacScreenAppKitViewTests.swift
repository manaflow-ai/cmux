import AppKit
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import CmuxNextWakeups
import CmuxScreenKit
import Foundation
import Testing

nonisolated private let viewDeviceID = "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff"

/// Every view under `root`, depth first.
@MainActor
private func views(under root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + views(under: $0) }
}

/// The view under `root` with accessibility identifier `id`.
@MainActor
private func findView(_ id: String, under root: NSView) -> NSView? {
    views(under: root).first { $0.accessibilityIdentifier() == id }
}

/// The text of every label under `root`.
@MainActor
private func texts(under root: NSView) -> [String] {
    views(under: root).compactMap { ($0 as? NSTextField)?.stringValue }
}

/// Lets the views' Observation updates (main-actor tasks) run until `condition` holds.
@MainActor
private func settle(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

/// Mac Screen's surfaces are AppKit (plans/cmux-next/no-swiftui-DESIGN.md): no hosting bridge,
/// and their controls run the models and follow them.
@MainActor @Suite(.serialized, .closesItsWindows)
struct MacScreenAppKitViewTests {
    private func window(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        content.frame = window.contentView?.bounds ?? .zero
        content.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(content)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func makePages() -> MacScreenPages {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        return MacScreenPages(store: MacScreenStore(file: file, removeLinkPairings: {}), work: BackgroundWork())
    }

    @Test func noSurfaceBuildsAHostingView() throws {
        let pages = makePages()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let home = pages.makeView(for: "home")
        let pane = MacScreenPane(hubDevice: MacScreenHubViewer(deviceID: viewDeviceID) { nil }, name: "Studio", preferences: ScreenPreferences())
        let prompt = MacScreenApprovalPrompt()
        prompt.present = { _ in }
        prompt.update([SessionRequest(id: "s1", viewerId: "v1", viewerName: "Laptop", scope: .view)])
        let approval = MacScreenApprovalView(prompt: prompt)
        for root in [home, pane.view, approval] as [NSView] {
            for view in views(under: root) {
                #expect(!String(describing: type(of: view)).contains("Hosting"), "\(type(of: view)) under \(type(of: root))")
            }
        }
        pane.close()
        pages.tabClosed("home")
        prompt.update([])
    }

    @Test func homeSaysHowToSetUpAndFollowsTheHubAddress() async throws {
        let pages = makePages()
        pages.hubConfigured = true
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        let window = window(tab)
        let signIn = (MacScreenHomeSnapshot.setupDevices(configured: true).note ?? "")
        let invalid = (MacScreenHomeSnapshot.setupDevices(configured: false).note ?? "")
        #expect(texts(under: tab).contains(signIn))
        #expect(texts(under: tab).contains(L.t("macScreen.home.yourDevices", "Your Devices")))
        // A model change redraws the page without a new view.
        pages.hubConfigured = false
        #expect(await settle { texts(under: tab).contains(invalid) })
        #expect(!texts(under: tab).contains(signIn))
        pages.tabClosed("home")
        window.close()
    }

    /// Leo 2026-11-16 ("this needs to shut up"): an offline Mac has no buttons and no instructions; offline Macs
    /// fold under one Offline row that opens to their names.
    @Test func offlineMacsFoldUnderOneRowWithNoButtonsOrInstructions() throws {
        let pages = makePages()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        let home = try #require(views(under: tab).compactMap { $0 as? MacScreenHomeView }.first)
        let device = MacScreenHomeSnapshot.Device(id: viewDeviceID, name: "Air Blue", isPhone: false,
                                                   online: false, macScreenShared: true, access: MacScreenAccess(.ask))
        home.build(MacScreenHomeSnapshot(devices: .list([device]), sharingLook: .list))
        #expect(!texts(under: home).contains("Open cmux on Air Blue to share its screen."))
        #expect(findView("macScreen.home.view.Air Blue", under: home) == nil)
        #expect(findView("macScreen.home.control.Air Blue", under: home) == nil)
        #expect(findView("macScreen.home.name.Air Blue", under: home) == nil)
        let group = try #require(findView("macScreen.home.offlineGroup", under: home) as? NSButton)
        // The group says what it holds (a symbol-only button once drew just the chevron).
        #expect(group.attributedTitle.string == "Offline (1)")
        group.performClick(nil)
        #expect(findView("macScreen.home.name.Air Blue", under: home) != nil)
        #expect(findView("macScreen.home.view.Air Blue", under: home) == nil)
        pages.tabClosed("home")
    }

    /// The classic look (Debug Settings) keeps the rows from before 2026-11-16 for comparison.
    @Test func classicLookKeepsTheOldRows() throws {
        let pages = makePages()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        let home = try #require(views(under: tab).compactMap { $0 as? MacScreenHomeView }.first)
        let device = MacScreenHomeSnapshot.Device(id: viewDeviceID, name: "Air Blue", isPhone: false,
                                                   online: false, macScreenShared: true, access: MacScreenAccess(.ask))
        home.build(MacScreenHomeSnapshot(devices: .list([device]), sharingLook: .list, devicesLook: .classic))
        #expect(texts(under: home).contains("Open cmux on Air Blue to share its screen."))
        #expect((findView("macScreen.home.view.Air Blue", under: home) as? NSButton)?.isEnabled == false)
        pages.tabClosed("home")
    }

    /// A usable Mac says nothing about access: name, dot and the buttons.
    @Test func askAccessSaysNothing() throws {
        let pages = makePages()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        let home = try #require(views(under: tab).compactMap { $0 as? MacScreenHomeView }.first)
        let device = MacScreenHomeSnapshot.Device(id: viewDeviceID, name: "Studio", isPhone: false,
                                                   online: true, macScreenShared: true, access: MacScreenAccess(.ask))
        home.build(MacScreenHomeSnapshot(devices: .list([device]), sharingLook: .list))
        let shown = texts(under: home)
        #expect(!shown.contains("The first connect asks on that Mac."))
        #expect(!shown.contains { $0.hasPrefix("Your access") })
        #expect(shown.contains("Studio"))
        #expect((findView("macScreen.home.control.Studio", under: home) as? NSButton)?.isEnabled == true)
        pages.tabClosed("home")
    }

    @Test func firstUseGuideNamesTheTwoSharingSteps() throws {
        let pages = makePages()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        let home = try #require(views(under: tab).compactMap { $0 as? MacScreenHomeView }.first)
        let sharing = MacScreenHomeSnapshot.Sharing(isSharing: false, busy: false, screenRecordingGranted: false,
                                                     accessibilityGranted: false, showFirstUse: true)
        home.build(MacScreenHomeSnapshot(sharing: sharing, sharingLook: .list))
        #expect(texts(under: home).contains("First time? 1. Turn on Allow Mac Screen on the other Mac. 2. Click View Only or Full Control here."))
        pages.tabClosed("home")
    }

    private func homeView(_ devices: [MacScreenHomeSnapshot.Device]) throws -> (MacScreenPages, MacScreenHomeView) {
        let pages = makePages()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        let home = try #require(views(under: tab).compactMap { $0 as? MacScreenHomeView }.first)
        home.build(MacScreenHomeSnapshot(devices: .list(devices), sharingLook: .list))
        return (pages, home)
    }

    /// A hub device maps to a row's values; its offline word counts only while this Mac's hub link is up.
    @Test func hubDevicesMapToRowsAndOfflineIsUnknownWhileTheHubReconnects() {
        let mac = HubDevice(id: "mac", name: "Office", platform: .macos, macScreenShared: true, online: false)
        let ask = MacScreenAccess(.ask)
        let connected = MacScreenHomeSnapshot.device(mac, access: ask, hubConnected: true)
        #expect(connected == MacScreenHomeSnapshot.Device(id: "mac", name: "Office", isPhone: false, online: false,
                                                           macScreenShared: true, access: ask, onlineKnown: true))
        #expect(!MacScreenHomeSnapshot.device(mac, access: ask, hubConnected: false).onlineKnown)
    }

    /// While the hub reconnects, a Mac last seen offline keeps View Only and Full Control and says nothing about it.
    @Test func aMacOfUnknownOnlineStateCanStillBeOpened() throws {
        let device = MacScreenHomeSnapshot.Device(id: viewDeviceID, name: "Office", isPhone: false, online: false,
                                                   macScreenShared: true, access: MacScreenAccess(.ask), onlineKnown: false)
        let (pages, home) = try homeView([device])
        #expect((findView("macScreen.home.view.Office", under: home) as? NSButton)?.isEnabled == true)
        #expect((findView("macScreen.home.control.Office", under: home) as? NSButton)?.isEnabled == true)
        #expect(!texts(under: home).contains("Open cmux on Office to share its screen."))
        pages.tabClosed("home")
    }

    /// Online, sharing and allowed: both buttons work. Sharing off: one short word, no buttons. Offline: folded.
    @Test func sharingOffSaysOneWordAndOnlineSharedRowsWork() throws {
        let ask = MacScreenAccess(.ask)
        let (pages, home) = try homeView([
            MacScreenHomeSnapshot.Device(id: "a", name: "Studio", isPhone: false, online: true, macScreenShared: true, access: ask),
            MacScreenHomeSnapshot.Device(id: "b", name: "Office", isPhone: false, online: true, macScreenShared: false, access: ask),
            MacScreenHomeSnapshot.Device(id: "c", name: "Den", isPhone: false, online: false, macScreenShared: true, access: ask),
        ])
        #expect((findView("macScreen.home.view.Studio", under: home) as? NSButton)?.isEnabled == true)
        #expect((findView("macScreen.home.control.Studio", under: home) as? NSButton)?.isEnabled == true)
        #expect((findView("macScreen.home.notShared.Office", under: home) as? NSTextField)?.stringValue == "Sharing off")
        #expect(findView("macScreen.home.view.Office", under: home) == nil)
        #expect(findView("macScreen.home.name.Den", under: home) == nil)
        #expect((findView("macScreen.home.offlineGroup", under: home) as? NSButton) != nil)
        pages.tabClosed("home")
    }

    /// A Mac that blocks this one says so even while its sharing is off: turning sharing on would not let this Mac in.
    @Test func aBlockingMacSaysItBlocksEvenWithSharingOff() throws {
        let device = MacScreenHomeSnapshot.Device(id: "a", name: "Office", isPhone: false, online: true,
                                                   macScreenShared: false, access: MacScreenAccess(.none))
        let (pages, home) = try homeView([device])
        #expect(findView("macScreen.home.blocked.Office", under: home) != nil)
        #expect(!texts(under: home).contains("Turn on Allow Mac Screen on Office to share its screen."))
        pages.tabClosed("home")
    }

    /// Macs are listed whether or not they are online or sharing; a phone only when it shares (never, today).
    @Test func listsEveryMacButOnlySharingPhones() {
        let devices = [
            HubDevice(id: "mac-offline", name: "Office", platform: .macos, macScreenShared: true, online: false),
            HubDevice(id: "mac-off", name: "Studio", platform: .macos, macScreenShared: false, online: true),
            HubDevice(id: "phone", name: "Phone", platform: .ios, macScreenShared: false, online: true),
        ]
        #expect(MacScreenHomeSnapshot.listed(devices).map(\.id) == ["mac-offline", "mac-off"])
    }

    @Test func connectCardButtonsAskTheHubAndTheCardFollows() async throws {
        let pane = MacScreenPane(hubDevice: MacScreenHubViewer(deviceID: viewDeviceID) { nil }, name: "Studio", preferences: ScreenPreferences())
        let window = window(pane.view)
        #expect(pane.model.card == .hubConnect)
        #expect(texts(under: pane.view.chrome.card).contains(String(format: L.t("macScreen.hub.connectTitle", "Connect to %@"), "Studio")))
        let full = try #require(findView("macScreen.hub.connectFull", under: pane.view.chrome.card) as? NSButton)
        #expect(findView("macScreen.hub.connectView", under: pane.view.chrome.card) is NSButton)
        // Return presses Full Control, as the card shows.
        #expect(full.keyEquivalent == "\r")
        full.performClick(nil)
        // Signed out: the hub refuses at once, and the card says so.
        #expect(pane.model.card == .hubRefused(.notSignedIn, requested: .full))
        let refusedTitle = L.t("macScreen.hub.signedOutTitle", "Not Signed In")
        #expect(await settle { texts(under: pane.view.chrome.card).contains(refusedTitle) })
        #expect(findView("macScreen.card.retry", under: pane.view.chrome.card) is NSButton)
        pane.view.layoutSubtreeIfNeeded()
        let card = pane.view.chrome.card.frame
        #expect(card.width == MacScreenCardView.width && card.height > 100)
        #expect(pane.view.screenRect.contains(CGPoint(x: card.midX, y: card.midY)))
        pane.close()
        window.close()
    }

    @Test func toolbarShowsTheNameAndHidesStreamControlsBeforeASession() async throws {
        let pane = MacScreenPane(hubDevice: MacScreenHubViewer(deviceID: viewDeviceID) { nil }, name: "Studio", preferences: ScreenPreferences())
        let window = window(pane.view)
        let toolbar = pane.view.chrome.toolbar
        #expect(texts(under: toolbar).contains("Studio"))
        for id in ["macScreen.quality", "macScreen.sendKeys", "macScreen.disconnect", "macScreen.connect", "macScreen.access", "macScreen.fullScreen", "macScreen.more"] {
            #expect(findView(id, under: toolbar)?.isHidden == true, "\(id)")
        }
        pane.model.name = "Studio 2"
        #expect(await settle { texts(under: toolbar).contains("Studio 2") })
        pane.close()
        window.close()
    }

    @Test func approvalShowsTheRequestAndItsFourAnswers() throws {
        let prompt = MacScreenApprovalPrompt()
        prompt.present = { _ in }
        let fingerprint = String(repeating: "ab", count: 32)
        prompt.update([SessionRequest(id: "s1", viewerId: "v1", viewerName: "Laptop", viewerKeyFingerprint: fingerprint, scope: .full)])
        let view = MacScreenApprovalView(prompt: prompt)
        let shown = texts(under: view)
        #expect(shown.contains(String(format: L.t("macScreen.approval.titleFull", "%@ wants to control this Mac"), "Laptop")))
        #expect(shown.contains(DeviceIdentity.displayFingerprint(fingerprint)))
        for id in ["macScreen.approval.deny", "macScreen.approval.once", "macScreen.approval.alwaysView", "macScreen.approval.alwaysFull"] {
            #expect(findView(id, under: view) is NSButton, "\(id)")
        }
        let size = view.fittingSize
        #expect(size.width == MacScreenApprovalView.width && size.height > 100)
        prompt.update([])
    }
}
