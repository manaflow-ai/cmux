import CmuxNextDaemon
@testable import CmuxNextMacScreen
import CmuxScreenKit
import Foundation
import Testing

/// The attached app's Mac Screen capture runs in cmux Remote's Screen Sharing worker
/// (docs/cmux-remote.md, "Attached capture"): the app reads and asks for cmux Remote's grants,
/// and only a worker that serves both session kinds takes the app's sessions.
@MainActor
@Suite struct AttachedCaptureInRemoteTests {
    private func hostStatus(serves: [String]?, screen: Bool = true, control: Bool = false) -> CmuxNextDaemon.JSONValue {
        var host: [String: CmuxNextDaemon.JSONValue] = [
            "name": .string("cmux Remote (dev)"),
            "permissions": .object(["screen_recording": .bool(screen), "accessibility": .bool(control)]),
        ]
        if let serves { host["screen"] = .object(["serves": .array(serves.map(CmuxNextDaemon.JSONValue.string))]) }
        return .object(host)
    }

    @Test func aWorkerServingBothKindsTakesTheAppsCapture() {
        let both = hostStatus(serves: [AttachedScreenHost.rdKind, AttachedScreenHost.webRTCKind])
        #expect(CmuxRemoteService.attachedCaptureKinds(both) == [AttachedScreenHost.rdKind, AttachedScreenHost.webRTCKind])
        #expect(CmuxRemoteService.attachedCaptureGrants(both)
            == MacScreenRemoteGrants.Read(screenRecording: true, accessibility: false, name: "cmux Remote (dev)"))
    }

    /// An older pinned cmux Remote lists nothing (or only WebRTC, without its cmux.rd/1 host):
    /// the app's helper or the app keeps serving, and its grants are the ones shown.
    @Test(arguments: [nil, [], [AttachedScreenHost.webRTCKind]] as [[String]?])
    func anOlderWorkerLeavesTheCaptureToTheApp(serves: [String]?) {
        let status = hostStatus(serves: serves)
        #expect(CmuxRemoteService.attachedCaptureKinds(status).isEmpty)
        #expect(CmuxRemoteService.attachedCaptureGrants(status) == nil)
    }

    @Test func cmuxRemotesGrantsWinOverTheHelpersAndTheApps() async {
        let host = MacScreenShareHost()
        host.helper = { nil }
        host.readPermissions = { (false, false) }
        host.remoteGrants = MacScreenRemoteGrants(read: {
            MacScreenRemoteGrants.Read(screenRecording: true, accessibility: true, name: "cmux Remote")
        }, request: { _ in true })
        await host.refreshPermissions()
        #expect(host.screenRecordingGranted)
        #expect(host.accessibilityGranted)
        #expect(host.grantHolderName == "cmux Remote")

        // cmux Remote stops serving the app's capture: the app's own read decides again.
        host.remoteGrants = MacScreenRemoteGrants(read: { nil }, request: { _ in false })
        await host.refreshPermissions()
        #expect(!host.screenRecordingGranted)
        #expect(host.grantHolderName == nil)
    }

    /// The setup sheet's Screen Recording steps name the process macOS lists.
    @Test func theSetupSheetNamesTheGrantHolder() {
        for step in [CmuxRemoteSharingSetup.Step.screen, .screenCheck] {
            let named = CmuxRemoteSharingSetup.spec(step, holder: "cmux Remote")
            #expect(named.lines.count == 2)
            #expect(named.lines.allSatisfy { $0.contains("cmux Remote") })
            #expect(CmuxRemoteSharingSetup.spec(step).lines != named.lines)
        }
    }
}
