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

    @Test func offlineDeviceExplainsHowToBringItBackWithNoActions() throws {
        let device = MacScreenHomeSnapshot.Device(id: viewDeviceID, name: "Air Blue", online: false, macScreenShared: true,
                                                   access: MacScreenAccess(.ask))
        let (pages, home) = try homeView([device])
        #expect(texts(under: home).contains("Open cmux on Air Blue to share its screen."))
        // No disabled buttons: the line says why, and nothing is drawn to press.
        #expect(findView("macScreen.home.connect.Air Blue", under: home) == nil)
        #expect(findView("macScreen.home.more.Air Blue", under: home) == nil)
        pages.tabClosed("home")
    }

    /// A device on the user's own account: no "Your access" line, one action (Connect, Full Control) and a menu.
    @Test func ownDeviceRowHasOneConnectActionAndNoAccessLine() throws {
        var opened: [(String, SessionScope?)] = []
        let device = MacScreenHomeSnapshot.Device(id: viewDeviceID, name: "Studio", online: true, macScreenShared: true,
                                                   access: MacScreenAccess(.ask))
        let (pages, home) = try homeView([device]) { $0.openDevice = { opened.append(($0, $1)) } }
        #expect(!texts(under: home).contains { $0.hasPrefix("Your access") })
        #expect(!texts(under: home).contains("The first connect asks on that Mac."))
        let connect = try #require(findView("macScreen.home.connect.Studio", under: home) as? NSButton)
        #expect(connect.isEnabled)
        #expect(findView("macScreen.home.view.Studio", under: home) == nil)
        #expect(findView("macScreen.home.control.Studio", under: home) == nil)
        connect.performClick(nil)
        #expect(opened.map(\.0) == [viewDeviceID])
        #expect(opened.map(\.1) == [.full])
        pages.tabClosed("home")
    }

    /// The menu: View Only, both in a new tab; the device's own switch for this Mac only when it is known.
    @Test func rowMenuOffersViewOnlyAndTheDevicesSwitchWhenKnown() throws {
        var sets: [(String, Bool)] = []
        let known = MacScreenHomeSnapshot.Device(id: "a", name: "Studio", online: true, macScreenShared: true,
                                                  access: MacScreenAccess(.ask), allowsThisMac: true)
        let (pages, home) = try homeView([known]) { actions in
            actions.remoteAccess = MacScreenRemoteAccess(allows: { _, _ in true }, set: { id, _, on in sets.append((id, on)) })
        }
        let menu = home.moreMenu(known)
        #expect(menu.items.map(\.title) == ["View Only", "", "Connect in New Tab", "View Only in New Tab", "", "Allow Screen Sharing"])
        let allow = try #require(menu.items.last)
        #expect(allow.state == .on)
        _ = (allow.target as? MacScreenMenuAction)?.choose(nil)
        #expect(sets.map(\.0) == ["a"])
        #expect(sets.map(\.1) == [false])
        var unknown = known
        unknown.allowsThisMac = nil
        #expect(home.moreMenu(unknown).items.map(\.title) == ["View Only", "", "Connect in New Tab", "View Only in New Tab"])
        pages.tabClosed("home")
    }

    @Test func firstUseGuideSaysConnect() throws {
        let pages = makePages()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        let home = try #require(views(under: tab).compactMap { $0 as? MacScreenHomeView }.first)
        let sharing = MacScreenHomeSnapshot.Sharing(isSharing: false, busy: false, screenRecordingGranted: false,
                                                     accessibilityGranted: false, showFirstUse: true)
        home.build(MacScreenHomeSnapshot(sharing: sharing, sharingLook: .simple))
        #expect(texts(under: home).contains("First time? Open cmux on the other Mac, then click Connect here."))
        pages.tabClosed("home")
    }

    private func homeView(_ devices: [MacScreenHomeSnapshot.Device], look: MacScreenDevicesLook = .connect,
                          actions edit: (inout MacScreenHomeActions) -> Void = { _ in }) throws -> (MacScreenPages, MacScreenHomeView) {
        let pages = makePages()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        let shown = try #require(views(under: tab).compactMap { $0 as? MacScreenHomeView }.first)
        var actions = MacScreenHomeActions()
        edit(&actions)
        let home = MacScreenHomeView(host: shown.host, actions: actions)
        home.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
        home.build(MacScreenHomeSnapshot(devices: .list(devices), sharingLook: .simple, devicesLook: look))
        return (pages, home)
    }

    /// A hub device maps to a row's values; its offline word counts only while this Mac's hub link is up.
    @Test func hubDevicesMapToRowsAndOfflineIsUnknownWhileTheHubReconnects() {
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        let mac = HubDevice(id: "mac", name: "Office", platform: .macos, lastSeenAt: seen, macScreenShared: true, online: false)
        let ask = MacScreenAccess(.ask)
        let connected = MacScreenHomeSnapshot.device(mac, access: ask, hubConnected: true)
        #expect(connected == MacScreenHomeSnapshot.Device(id: "mac", name: "Office", platform: .macos, online: false,
                                                           macScreenShared: true, access: ask, onlineKnown: true, lastSeen: seen))
        #expect(!MacScreenHomeSnapshot.device(mac, access: ask, hubConnected: false).onlineKnown)
        #expect(!connected.connectable)
    }

    /// While the hub reconnects, a Mac last seen offline keeps Connect and says nothing about it.
    @Test func aMacOfUnknownOnlineStateCanStillBeOpened() throws {
        let device = MacScreenHomeSnapshot.Device(id: viewDeviceID, name: "Office", online: false, macScreenShared: true,
                                                   access: MacScreenAccess(.ask), onlineKnown: false)
        let (pages, home) = try homeView([device])
        #expect((findView("macScreen.home.connect.Office", under: home) as? NSButton)?.isEnabled == true)
        #expect(!texts(under: home).contains("Open cmux on Office to share its screen."))
        pages.tabClosed("home")
    }

    /// Online and sharing: Connect. Sharing off: the row says so in a whole sentence, with its own id. In every look.
    @Test(arguments: MacScreenDevicesLook.allCases)
    func sharingOffSaysSoAndOnlineSharedRowsConnect(_ look: MacScreenDevicesLook) throws {
        let ask = MacScreenAccess(.ask)
        let (pages, home) = try homeView([
            MacScreenHomeSnapshot.Device(id: "a", name: "Studio", online: true, macScreenShared: true, access: ask),
            MacScreenHomeSnapshot.Device(id: "b", name: "Mini", online: true, macScreenShared: false, access: ask),
            MacScreenHomeSnapshot.Device(id: "c", name: "Den", online: false, macScreenShared: true, access: ask),
        ], look: look)
        #expect(findView("macScreen.home.connect.Studio", under: home) is NSButton)
        #expect((findView("macScreen.home.notShared.Mini", under: home) as? NSTextField)?.stringValue
            == "Screen sharing is off on Mini.")
        #expect(findView("macScreen.home.connect.Mini", under: home) == nil)
        #expect((findView("macScreen.home.offline.Den", under: home) as? NSTextField)?.stringValue
            == "Open cmux on Den to share its screen.")
        // The reason wraps: its label is a wrapping field, never cut off at one line.
        let reason = try #require(findView("macScreen.home.notShared.Mini", under: home) as? NSTextField)
        #expect(reason.cell?.wraps == true)
        pages.tabClosed("home")
    }

    /// A Mac that blocks this one says so even while its sharing is off: turning sharing on would not let this Mac in.
    @Test func aBlockingMacSaysItBlocksEvenWithSharingOff() throws {
        let device = MacScreenHomeSnapshot.Device(id: "a", name: "Office", online: true, macScreenShared: false,
                                                   access: MacScreenAccess(.none))
        let (pages, home) = try homeView([device])
        #expect(findView("macScreen.home.blocked.Office", under: home) != nil)
        #expect(!texts(under: home).contains("Screen sharing is off on Office."))
        pages.tabClosed("home")
    }

    /// Each platform draws its own glyph; Windows and Linux come from the hub's platform, not made-up rows.
    @Test func platformGlyphs() {
        #expect(MacScreenHomeView.glyph(.macos) == "desktopcomputer")
        #expect(MacScreenHomeView.glyph(nil) == "desktopcomputer")
        #expect(MacScreenHomeView.glyph(.ios) == "iphone")
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
