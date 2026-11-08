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

    /// With both permissions and no viewer, the status says this Mac is ready.
    @Test func statusIsReadyWithBothPermissions() throws {
        try withHome { home in
            let shown = texts(under: home.sharingSection(sharing(screenRecording: true, accessibility: true)))
            #expect(shown.contains(Self.ready), "\(shown)")
        }
    }
}
