import AppKit
import Testing
@testable import CmuxControlSocket
import CmuxSettings

@MainActor
@Suite("ApplicationTerminateReplyCoordinator", .serialized)
struct ApplicationTerminateReplyCoordinatorTests {
    @Test("will-terminate teardown snapshots before teardown side effects")
    func teardownOrderMatchesMainWithoutWatchdog() {
        let host = RecordingTerminationHost()
        let coordinator = ApplicationTerminateReplyCoordinator(host: host)

        coordinator.performTeardown()

        #expect(host.events == [
            "breadcrumb:appDelegate.willTerminate.begin",
            "setTerminating:true",
            "snapshot",
            "flushClosedItems",
            "stopSentry",
            "detachRemoteTmux",
            "presenceGoodbye",
            "closeInspectors",
            "stopAutosave",
            "terminateCloudVM",
            "terminateSSHURL",
            "stopMobileHost",
            "stopTerminal",
            "cleanupPasteboardTemps",
            "stopVSCode",
            "flushBrowserProfiles",
            "cancelGhosttyCrashTask",
            "clearNotifications",
            "markGhosttyCleanExit",
            "breadcrumb:appDelegate.willTerminate.complete",
            "enableSuddenTermination"
        ])
    }

    @Test("active quit confirmation pending reply short-circuits before new effects")
    func activeConfirmationPendingReplyShortCircuitsBeforeSnapshotAndPresentation() {
        let shortcutOwnedHost = RecordingTerminationHost(pendingReply: .terminateCancel)
        let shortcutOwnedCoordinator = ApplicationTerminateReplyCoordinator(host: shortcutOwnedHost)

        #expect(
            shortcutOwnedCoordinator.applicationShouldTerminate(
                isDevBuild: false,
                buildFlavorRawValue: "release"
            ) == .terminateCancel
        )
        #expect(shortcutOwnedHost.events == ["pending:false"])

        let terminateOwnedHost = RecordingTerminationHost(pendingReply: .terminateLater)
        let terminateOwnedCoordinator = ApplicationTerminateReplyCoordinator(host: terminateOwnedHost)

        #expect(
            terminateOwnedCoordinator.applicationShouldTerminate(
                isDevBuild: false,
                buildFlavorRawValue: "release"
            ) == .terminateLater
        )
        #expect(terminateOwnedHost.events == ["pending:false"])
    }

    @Test("canceling a quit confirmation does not snapshot")
    func cancelledConfirmationDoesNotSnapshot() throws {
        let defaultsSnapshot = StandardQuitConfirmationDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }
        QuitConfirmationStore(defaults: .standard).setMode(.always)

        let host = RecordingTerminationHost()
        let coordinator = ApplicationTerminateReplyCoordinator(host: host)

        #expect(
            coordinator.applicationShouldTerminate(
                isDevBuild: false,
                buildFlavorRawValue: "release"
            ) == .terminateLater
        )
        #expect(host.events.contains("present:true"))
        #expect(!host.events.contains("snapshot"))

        let completion = try #require(host.presentedCompletion)
        completion(.alertSecondButtonReturn, .off)

        #expect(!host.events.contains("snapshot"))
        #expect(host.events.contains("reply:false"))
    }

    @Test("confirming a quit confirmation snapshots after the alert response")
    func confirmedConfirmationSnapshotsAfterUserDecision() throws {
        let defaultsSnapshot = StandardQuitConfirmationDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }
        QuitConfirmationStore(defaults: .standard).setMode(.always)

        let host = RecordingTerminationHost()
        let coordinator = ApplicationTerminateReplyCoordinator(host: host)

        #expect(
            coordinator.applicationShouldTerminate(
                isDevBuild: false,
                buildFlavorRawValue: "release"
            ) == .terminateLater
        )

        let presentIndex = try #require(host.events.firstIndex(of: "present:true"))
        let completion = try #require(host.presentedCompletion)
        completion(.alertFirstButtonReturn, .off)
        let snapshotIndex = try #require(host.events.firstIndex(of: "snapshot"))

        #expect(presentIndex < snapshotIndex)
        #expect(host.events.contains("reply:true"))
    }
}
