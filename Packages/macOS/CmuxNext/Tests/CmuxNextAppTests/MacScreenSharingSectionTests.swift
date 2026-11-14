import AppKit
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

    private func withHome(_ body: (MacScreenHomeView) throws -> Void) throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file, removeLinkPairings: {}), work: BackgroundWork())
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

    /// With both permissions and no viewer, the status says this Mac is ready.
    @Test func statusIsReadyWithBothPermissions() throws {
        try withHome { home in
            let shown = texts(under: home.sharingSection(sharing(screenRecording: true, accessibility: true)))
            #expect(shown.contains(Self.ready), "\(shown)")
        }
    }
}
