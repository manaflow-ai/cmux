import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemonService
import CmuxNextSidebar
import Foundation
import Testing

/// "i feel like the restarted after nightly update does too many layout shifts/flicker renderings" (Leo). On an
/// update relaunch the app's sidebar document started (the first `sidebarLayout` read, 175 to 211 ms after the
/// process start) before the daemon applied its launch snapshot (212 to 257 ms), so it never saw the snapshot's
/// document. The first window then drew its top items in the band above the list, and moved them into the list
/// (32 pt) once the daemon's `sidebar.get` answered, 600 ms in (relaunch-shift bench, cmuxterm-hq#6338).
@MainActor @Suite struct SidebarDocLateLaunchSnapshotTests {
    @Test func aLaunchSnapshotAppliedAfterTheDocumentStartedIsShownBeforeTheFirstWindow() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        _ = services.sidebarLayout // the document starts: no launch snapshot yet
        #expect(services.sidebarDoc.drag(room: nil) == nil)

        services.machines.local.receiveLaunchSnapshotSidebarDoc(Data(SidebarDocLaunchSnapshotTests.document.utf8))
        #expect(services.sidebarDoc.store?.isProvisional == true, "the late launch snapshot's document was not loaded")
        #expect(services.sidebarDoc.drag(room: nil) != nil,
                "the first window seeds with no document: its top items draw in the band, then move into the list")
        #expect(services.machines.local.launchSnapshotSidebarDoc == nil, "the document is read once")
    }
}
