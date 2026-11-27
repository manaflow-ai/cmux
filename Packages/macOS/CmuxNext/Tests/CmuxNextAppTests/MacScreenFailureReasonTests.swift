@testable import CmuxNextMacScreen
import CmuxNextRemoteView
import Foundation
import Testing

// A failed Mac Screen tab says the real reason (hq#13721 item 2: the card said "Check that Air
// Blue is awake and online" for a session whose link was Direct at 7 ms and whose host had
// started capture). The host's own `ended` reason reaches the card over the link (cmux.rd/1
// `ended`, `cmux rd connect`'s `host: ` line) and through the hub (`failed: <reason>` in its
// end); the awake-and-online text is left only for a session where nobody said anything.

struct MacScreenHostEndTests {
    /// The host's `failed: <error>` (cmux-rd-host `serve.rs`) is a host failure with its error;
    /// any other reason is the host stopping, and a stop this viewer sent stays its own.
    @Test func theHostsFailedEndKeepsItsReason() {
        var handshake = RemoteRdHandshake(service: "desktop")
        handshake.receive(Data(#"{"t":"ended","reason":"failed: capture: no frame from the display"}"#.utf8))
        #expect(handshake.phase == .ended(.hostFailed(reason: "capture: no frame from the display")))

        #expect(RemoteRdHandshake.hostEnd("failed") == .hostFailed(reason: ""))
        #expect(RemoteRdHandshake.hostEnd("stopped by the host") == .hostStoppedSharing)
        #expect(RemoteRdHandshake.hostEnd("failedness") == .hostStoppedSharing)

        var stopped = RemoteRdHandshake(service: "desktop")
        stopped.viewerStopped()
        stopped.receive(Data(#"{"t":"ended","reason":"failed: capture"}"#.utf8))
        #expect(stopped.phase == .ended(.stoppedByViewer))
    }

    /// `cmux rd connect`'s `ended` line (cmux-rd-host `connect.rs`): who failed, and why.
    @Test func theLinkBridgesEndNamesWhoFailed() {
        #expect(MacScreenSession.failureCause(ofEnded: "host: failed: capture: denied") == .host("capture: denied"))
        #expect(MacScreenSession.failureCause(ofEnded: "host: stopped by the host") == nil)
        #expect(MacScreenSession.failureCause(ofEnded: "link failed: no route (2 routes)") == .link("no route (2 routes)"))
        #expect(MacScreenSession.failureCause(ofEnded: "failed: pane socket") == .link("pane socket"))
        #expect(MacScreenSession.failureCause(ofEnded: "the host ended the session") == nil)
        #expect(MacScreenSession.failureCause(ofEnded: "stopped by the viewer") == nil)
    }

    /// The hub's `failed: <reason>`: still a failure, with its detail; a bare `failed` has none.
    @Test func theHubsFailedEndCarriesTheHostsReason() {
        #expect(MacScreenEndReason("failed: no Screen Sharing helper: none installed") == .failed)
        #expect(MacScreenEndReason("failed") == .failed)
        #expect(MacScreenEndReason.failureDetail("failed: the screen host stopped") == "the screen host stopped")
        #expect(MacScreenEndReason.failureDetail("failed") == "")
        #expect(MacScreenEndReason.failureDetail("host_stopped") == nil)
        #expect(MacScreenEndReason.failureDetail(nil) == nil)
    }

    /// What this Mac sends as a host that could not serve: the same form cmux-hub-host sends.
    @Test func theHostsEndTextFitsTheHub() {
        #expect(MacScreenHubReason.failure("") == "failed")
        #expect(MacScreenHubReason.failure("the screen host could not start: x") == "failed: the screen host could not start: x")
        #expect(MacScreenHubReason.failure("failed: capture\nline two") == "failed: capture line two")
        let long = MacScreenHubReason.failure(String(repeating: "é", count: 300))
        #expect(long.utf16.count <= MacScreenHubReason.hubReasonLimit)
        #expect(long.hasPrefix("failed: é"))
        // Round trip: the viewer reads back what the host sent.
        #expect(MacScreenEndReason.failureDetail(MacScreenHubReason.failure("capture: denied")) == "capture: denied")
    }
}

@MainActor
struct MacScreenFailedCardTests {
    private let generic = MacScreenPaneModel.failedDetail(relayErrors: [], relayOnly: false, hubTab: true, name: "Air Blue")

    /// The host's reason is the card's detail, before any guess; the guess stays for silence.
    @Test func theHostsReasonIsTheDetail() {
        let host = MacScreenPaneModel.failedDetail(relayErrors: [], relayOnly: true, hubTab: true, name: "Air Blue",
                                                   cause: .host("capture: no frame"))
        #expect(host.contains("Air Blue") && host.contains("capture: no frame"))
        #expect(!host.contains("awake"))
        let bare = MacScreenPaneModel.failedDetail(relayErrors: [], relayOnly: false, hubTab: true, name: "Air Blue", cause: .host(""))
        #expect(bare.contains("Air Blue") && bare != generic)
        // This Mac's own hub link down still says so first.
        let offline = MacScreenPaneModel.failedDetail(relayErrors: [], relayOnly: false, hubTab: true, name: "Air Blue",
                                                      hubOnline: false, cause: .host("x"))
        #expect(!offline.contains("x"))
        #expect(generic.contains("awake"))
    }

    /// The link's own failure, and a link that came up with no picture, never blame the host's power.
    @Test func aLinkThatCameUpNeverSaysAwakeAndOnline() {
        let link = MacScreenPaneModel.failedDetail(relayErrors: [], relayOnly: false, hubTab: true, name: "Air Blue",
                                                   cause: .link("no route"))
        #expect(link.contains("no route") && !link.contains("awake"))
        let up = MacScreenPaneModel.failedDetail(relayErrors: [], relayOnly: false, hubTab: true, name: "Air Blue", linkConnected: true)
        #expect(up.contains("Air Blue") && !up.contains("awake"))
    }

    /// The hub's `failed: <reason>` for this tab's session reaches the card, whether the stream
    /// failed first (the failed card) or not (the hub's ended card); a new request forgets it.
    @Test func theHubsReasonReachesBothCards() {
        let viewer = MacScreenHubViewer(deviceID: "host") { nil }
        viewer.phase = .streaming(sessionID: "s1", scope: .full)
        viewer.streamFailed()
        viewer.ended(reason: "failed: no Screen Sharing helper: none installed")
        #expect(viewer.phase == .streamFailed(sessionID: "s1", scope: .full))
        #expect(viewer.hostFailure == "no Screen Sharing helper: none installed")
        let model = MacScreenPaneModel(session: nil, name: "Air Blue", gate: .open, hub: viewer)
        #expect(model.failureCause == .host("no Screen Sharing helper: none installed"))

        let other = MacScreenHubViewer(deviceID: "host") { nil }
        other.phase = .streaming(sessionID: "s2", scope: .view)
        other.ended(reason: "failed: the screen host stopped")
        #expect(MacScreenPaneModel.hubCard(other.phase) == .hubEnded(.failed))
        let otherModel = MacScreenPaneModel(session: nil, name: "Air Blue", gate: .open, hub: other)
        #expect(otherModel.hubFailureDetail?.contains("the screen host stopped") == true)
        #expect(MacScreenCardView.failedDetail(.hubEnded(.failed), otherModel).contains("the screen host stopped"))
        #expect(MacScreenCardView.failedDetail(.hubEnded(.hostStopped), otherModel).isEmpty)

        // A bare `failed` (often this tab's own `/end` echoed back) names no one: no reason.
        let plain = MacScreenHubViewer(deviceID: "host") { nil }
        plain.phase = .streaming(sessionID: "s3", scope: .view)
        plain.ended(reason: "failed")
        #expect(plain.hostFailure == nil)
        // A new request forgets the last one's reason.
        other.request(.view)
        #expect(other.hostFailure == nil)
    }
}
