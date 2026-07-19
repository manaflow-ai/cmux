#if DEBUG
import Foundation
import Testing
@testable import CmuxMobileShellReleaseGateSupport

struct MobileIrohReleaseGateResponseValidatorTests {
    @Test
    func independentEventsRequireExactStreamAndIrohLaneThenRemoval() throws {
        let streamID = "gate-stream"
        let subscribed = try JSONSerialization.data(withJSONObject: [
            "stream_id": streamID,
            "already_subscribed": false,
            "event_transport": "iroh_server_events_v1",
        ])
        let controlFallback = try JSONSerialization.data(withJSONObject: [
            "stream_id": streamID,
            "event_transport": "control",
        ])
        let unsubscribed = try JSONSerialization.data(withJSONObject: [
            "stream_id": streamID,
            "removed": true,
        ])

        #expect(MobileIrohReleaseGateResponseValidator.independentEventSubscription(
            subscribed,
            expectedStreamID: streamID
        ))
        #expect(!MobileIrohReleaseGateResponseValidator.independentEventSubscription(
            controlFallback,
            expectedStreamID: streamID
        ))
        #expect(MobileIrohReleaseGateResponseValidator.independentEventUnsubscription(
            unsubscribed,
            expectedStreamID: streamID
        ))
    }

    @Test
    func notificationReconcileRejectsNegativeUnreadCount() throws {
        let valid = try JSONSerialization.data(withJSONObject: [
            "handled_ids": [],
            "unread_count": 0,
        ])
        let invalid = try JSONSerialization.data(withJSONObject: [
            "handled_ids": [],
            "unread_count": -1,
        ])

        #expect(MobileIrohReleaseGateResponseValidator.notificationReconcile(valid))
        #expect(!MobileIrohReleaseGateResponseValidator.notificationReconcile(invalid))
    }

    @Test
    func chatSessionsRequireDecodableSnapshot() throws {
        let valid = try JSONSerialization.data(withJSONObject: ["sessions": []])
        let invalid = try JSONSerialization.data(withJSONObject: [:])

        #expect(MobileIrohReleaseGateResponseValidator.chatSessions(valid))
        #expect(!MobileIrohReleaseGateResponseValidator.chatSessions(invalid))
    }

    @Test
    func artifactCountRequiresContentFreeNonnegativeResponse() throws {
        let valid = try JSONSerialization.data(withJSONObject: [
            "artifacts": [],
            "session_artifact_total": 0,
        ])
        let negative = try JSONSerialization.data(withJSONObject: [
            "artifacts": [],
            "session_artifact_total": -1,
        ])
        let contentBearing = try JSONSerialization.data(withJSONObject: [
            "artifacts": [["path": "/private/path"]],
            "session_artifact_total": 1,
        ])

        #expect(MobileIrohReleaseGateResponseValidator.artifactScanCount(valid))
        #expect(!MobileIrohReleaseGateResponseValidator.artifactScanCount(negative))
        #expect(!MobileIrohReleaseGateResponseValidator.artifactScanCount(contentBearing))
    }
}
#endif
