import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSidebar
import Foundation
import Testing

/// Each app instance owns its sidebar document (PATTERNS.md P1). The store was one process-wide static
/// (`SidebarDocStore.current`), set by each app's first `sidebarLayout` read: in the test process a second
/// `AppActions.bind`, as any suite running in parallel does, took the first app's document, and the first
/// app then read the other's (SidebarCmdNumberTwiceTests: "sidebar document active false, version 0, shown 0").
@MainActor @Suite struct SidebarDocPerAppTests {
    /// App `services` with its actions bound, whose first `sidebarLayout` read starts its document. With
    /// `document`, its home daemon's launch snapshot saved one: the document is active at once, with no daemon.
    private static func app(document: Data?) -> AppServices {
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.machines.local.launchSnapshotSidebarDoc = document
        AppActions.bind(services)
        return services
    }

    /// The archive actions run only on the app's active sidebar document (`ArchiveStrings.needsDocument` otherwise).
    private static func readsActiveDocument(_ services: AppServices) -> Bool {
        let idle = services.registry.unavailableReason(for: "workspace.archiveIdle")
        let toggle = services.registry.unavailableReason(for: "workspace.toggleArchive")
        #expect((idle == nil) == (toggle == nil), "the two archive actions read different documents: \(String(describing: idle)), \(String(describing: toggle))")
        return idle == nil
    }

    @Test func twoAppsInOneProcessEachReadTheirOwnSidebarDocument() {
        _ = NSApplication.shared
        let document = Data(SidebarDocLaunchSnapshotTests.document.utf8)
        let without = Self.app(document: nil)
        #expect(!Self.readsActiveDocument(without), "an app with no daemon and no snapshot has no active document")

        // Another app starts its own document: the first one keeps reading its own, inactive one.
        let with = Self.app(document: document)
        #expect(Self.readsActiveDocument(with), "the launch snapshot's document is not this app's")
        #expect(!Self.readsActiveDocument(without), "an app reads another app's sidebar document")

        // And the other way: a third app's start leaves the active one reading its own document.
        let third = Self.app(document: nil)
        #expect(!Self.readsActiveDocument(third))
        #expect(Self.readsActiveDocument(with), "a later app's start took this app's sidebar document")
    }
}
