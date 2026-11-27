import AppKit
import CmuxNextActions
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
import Testing

/// Every view under `root`, depth first.
@MainActor
private func views(under root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + views(under: $0) }
}

/// The text of every label under `root`.
@MainActor
private func texts(under root: NSView) -> [String] {
    views(under: root).compactMap { ($0 as? NSTextField)?.stringValue }
}

/// The home page's Allow Mac Screen section: its status says what this Mac can do now,
/// from the permissions it has.
@MainActor @Suite(.serialized, .closesItsWindows)
struct MacScreenSharingSectionTests {
    static let ready = L.t("macScreen.home.hubReady", "Ready. Your devices can connect.")

    private func withHome(configure: (MacScreenPages) -> Void = { _ in },
                          _ body: (MacScreenHomeView) throws -> Void) throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file, removeLinkPairings: {}), work: BackgroundWork())
        configure(pages)
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        let home = try #require(views(under: tab).compactMap { $0 as? MacScreenHomeView }.first)
        try body(home)
        pages.tabClosed("home")
    }

    private func sharing(screenRecording: Bool, accessibility: Bool,
                         session: MacScreenHubHost.Session? = nil) -> MacScreenHomeSnapshot.Sharing {
        MacScreenHomeSnapshot.Sharing(isSharing: true, busy: false, screenRecordingGranted: screenRecording,
                                      accessibilityGranted: accessibility, session: session, lastError: nil)
    }

    @Test(arguments: MacScreenSharingLook.allCases)
    func turningOnUsesRegisteredGuideWithoutEnablingHost(_ look: MacScreenSharingLook) throws {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        var guideRequests = 0
        _ = registry.bindEffect("macScreen.shareThisMac", effect: { _ in
            guideRequests += 1
            return .done
        })
        try withHome(configure: { pages in
            pages.useActions(of: registry)
            pages.events = MacScreenTabEvents()
        }) { home in
            var state = sharing(screenRecording: false, accessibility: false)
            state.isSharing = false
            home.build(MacScreenHomeSnapshot(sharing: state, sharingLook: look))
            let toggle = try #require(views(under: home).compactMap { $0 as? MacScreenSwitch }.first)

            #expect(toggle.accessibilityPerformPress())

            #expect(guideRequests == 1)
            #expect(home.devices?.hubHost.isSharing == false)
            #expect(home.devices?.hubHost.busy == false)
        }
    }

    @Test(arguments: MacScreenSharingLook.allCases)
    func turningOffDoesNotOpenGuide(_ look: MacScreenSharingLook) throws {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        var guideRequests = 0
        _ = registry.bindEffect("macScreen.shareThisMac", effect: { _ in
            guideRequests += 1
            return .done
        })
        try withHome(configure: { $0.useActions(of: registry) }) { home in
            home.build(MacScreenHomeSnapshot(sharing: sharing(screenRecording: true, accessibility: true), sharingLook: look))
            let toggle = try #require(views(under: home).compactMap { $0 as? MacScreenSwitch }.first)

            #expect(toggle.accessibilityPerformPress())

            #expect(guideRequests == 0)
            #expect(!toggle.isOn)
        }
    }

    /// Without Screen Recording no device can see this Mac: the status must not say it is ready.
    @Test func statusIsNotReadyWithoutScreenRecording() throws {
        try withHome { home in
            let shown = texts(under: home.sharingSection(sharing(screenRecording: false, accessibility: true)))
            #expect(!shown.contains(Self.ready), "\(shown)")
        }
    }

    /// Without Accessibility a device can only watch: the status says so, not a plain "Ready".
    @Test func statusSaysViewOnlyWithoutAccessibility() throws {
        try withHome { home in
            let shown = texts(under: home.sharingSection(sharing(screenRecording: true, accessibility: false)))
            #expect(!shown.contains(Self.ready), "\(shown)")
        }
    }

    /// The list look (the default): titled This Mac; a permission's detail shows only while it is missing,
    /// and its row then offers Open System Settings.
    @Test func listShowsPermissionDetailsOnlyWhileMissing() throws {
        try withHome { home in
            let needed = L.t("macScreen.home.screenRecordingNeeded", "Needed to send this screen. macOS may ask you to reopen cmux.")
            let open = L.t("macScreen.home.openSettings", "Open System Settings")
            let granted = home.sharingSection(sharing(screenRecording: true, accessibility: true), look: .list)
            #expect(texts(under: granted).first == L.t("devices.section.this", "This Mac"))
            #expect(!texts(under: granted).contains(needed))
            #expect(!views(under: granted).contains { ($0 as? NSButton)?.title == open })
            let missing = home.sharingSection(sharing(screenRecording: false, accessibility: true), look: .list)
            #expect(texts(under: missing).contains(needed))
            #expect(views(under: missing).contains { ($0 as? NSButton)?.title == open })
        }
    }

    /// This Mac not on the device hub yet (its socket reconnecting, run 45954248647): every look still draws
    /// This Mac with its switch and permissions, and says why the switch waits, not a page with only Your Devices.
    @Test(arguments: MacScreenSharingLook.allCases)
    func everyLookDrawsThisMacWhileTheHubReconnects(_ look: MacScreenSharingLook) throws {
        try withHome { home in
            var waiting = sharing(screenRecording: false, accessibility: false)
            waiting.isSharing = false
            waiting.busy = true
            waiting.hubNote = MacScreenHomeSnapshot.hubNote(.starting)
            let section = home.sharingSection(waiting, look: look)
            let ids = views(under: section).map { $0.accessibilityIdentifier() }
            #expect(ids.contains("macScreen.home.allowToggle"))
            #expect(ids.contains("macScreen.home.hubNote"))
            #expect(texts(under: section).contains(L.t("macScreen.home.thisMacJoining", "Connecting this Mac to the device hub…")))
            let failed = MacScreenHomeSnapshot.hubNote(.failed("timed out"))
            #expect(failed.contains("timed out"), "\(failed)")
        }
    }

    /// Every look draws the switch, and the status while sharing; off, no status and no permission rows.
    @Test(arguments: MacScreenSharingLook.allCases)
    func everyLookDrawsTheSwitchAndStatus(_ look: MacScreenSharingLook) throws {
        try withHome { home in
            let on = home.sharingSection(sharing(screenRecording: true, accessibility: true), look: look)
            let ids = views(under: on).map { $0.accessibilityIdentifier() }
            #expect(ids.contains("macScreen.home.allowToggle"))
            #expect(texts(under: on).contains(Self.ready))
            var off = sharing(screenRecording: true, accessibility: true)
            off.isSharing = false
            let offView = home.sharingSection(off, look: look)
            #expect(views(under: offView).contains { $0.accessibilityIdentifier() == "macScreen.home.allowToggle" })
            #expect(!texts(under: offView).contains(Self.ready))
            #expect(!texts(under: offView).contains(L.t("macScreen.home.screenRecording", "Screen Recording")))
        }
    }

    /// The simple look (the default, Leo 2026-11-16: "i hate the "you approve each one" ... it's too many ... steps"):
    /// no "approve each one", no per-permission rows; one Grant Access while a permission is missing, and
    /// who is connected with one Stop.
    @Test func simpleLookIsOneSwitchOneGrantAndStop() throws {
        #expect(MacScreenTunables.sharingLook.defaultValue == .simple)
        try withHome { home in
            let open = L.t("macScreen.home.openSettings", "Open System Settings")
            let missing = home.sharingSection(sharing(screenRecording: false, accessibility: false), look: .simple)
            #expect(!texts(under: missing).contains { $0.localizedCaseInsensitiveContains("approve each") })
            #expect(views(under: missing).filter { $0.accessibilityIdentifier() == "macScreen.home.grantAccess" }.count == 1)
            #expect(!views(under: missing).contains { ($0 as? NSButton)?.title == open })
            let granted = home.sharingSection(sharing(screenRecording: true, accessibility: true), look: .simple)
            #expect(!views(under: granted).contains { $0.accessibilityIdentifier() == "macScreen.home.grantAccess" })
            let session = MacScreenHubHost.Session(id: "s", viewerID: "v", viewerName: "Laptop", scope: .full, connected: true)
            let connected = home.sharingSection(sharing(screenRecording: true, accessibility: true, session: session), look: .simple)
            #expect(texts(under: connected).contains("Connected: Laptop · Controlling"))
            #expect(views(under: connected).filter { $0.accessibilityIdentifier() == "macScreen.home.stop" }.count == 1)
        }
    }

    /// With both permissions and no viewer, the status says this Mac is ready.
    @Test func statusIsReadyWithBothPermissions() throws {
        try withHome { home in
            let shown = texts(under: home.sharingSection(sharing(screenRecording: true, accessibility: true)))
            #expect(shown.contains(Self.ready), "\(shown)")
        }
    }
}
