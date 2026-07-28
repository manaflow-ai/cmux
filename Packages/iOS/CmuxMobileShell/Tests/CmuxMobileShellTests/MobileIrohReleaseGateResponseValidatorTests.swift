#if DEBUG
import CmuxAgentChat
import CmuxMobileShell
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
        #expect(MobileIrohReleaseGateResponseValidator.independentEventSubscription(
            subscribed,
            expectedStreamID: streamID,
            expectedAlreadySubscribed: false
        ))
        #expect(!MobileIrohReleaseGateResponseValidator.independentEventSubscription(
            subscribed,
            expectedStreamID: streamID,
            expectedAlreadySubscribed: true
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
    func artifactContinuityRequiresTheExactAuthorizedPathAndLaneDescriptor() throws {
        let path = "/tmp/cmux-iroh-gate.txt"
        let scan = try ChatWireCoding().encode(TerminalArtifactScanResponse(artifacts: [
            TerminalArtifactReference(
                path: path,
                kind: .text,
                displayName: "cmux-iroh-gate.txt",
                size: 12
            ),
        ]))
        let descriptor = ChatArtifactLaneDescriptor(
            resourceID: "opaque-resource",
            totalSize: 12,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let encodedDescriptor = try ChatWireCoding().encode(descriptor)

        #expect(MobileIrohReleaseGateResponseValidator.artifactPath(
            scan,
            expectedPath: path
        ))
        #expect(!MobileIrohReleaseGateResponseValidator.artifactPath(
            scan,
            expectedPath: "/tmp/other.txt"
        ))
        #expect(
            MobileIrohReleaseGateResponseValidator.artifactLaneDescriptor(encodedDescriptor)
                == descriptor
        )

        let stat = ChatArtifactStat(
            exists: true,
            isDirectory: false,
            size: 12,
            modifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
            kind: .text
        )
        let encodedStat = try ChatWireCoding().encode(stat)
        #expect(MobileIrohReleaseGateResponseValidator.artifactStat(
            encodedStat,
            expectedSize: 12
        ))
        #expect(!MobileIrohReleaseGateResponseValidator.artifactStat(
            encodedStat,
            expectedSize: 13
        ))
    }

    @Test
    func artifactContinuityAcceptsTheCanonicalMacOSTemporaryDirectoryAlias() throws {
        let scan = try ChatWireCoding().encode(TerminalArtifactScanResponse(artifacts: [
            TerminalArtifactReference(
                path: "/private/tmp/cmux-iroh-gate-test.bin",
                kind: .binary,
                displayName: "cmux-iroh-gate-test.bin",
                size: 12
            ),
        ]))

        #expect(MobileIrohReleaseGateResponseValidator.artifactPath(
            scan,
            expectedPath: "/tmp/cmux-iroh-gate-test.bin"
        ))
        #expect(!MobileIrohReleaseGateResponseValidator.artifactPath(
            scan,
            expectedPath: "/tmp/cmux-iroh-gate-other.bin"
        ))
        #expect(!MobileIrohReleaseGateResponseValidator.artifactPath(
            scan,
            expectedPath: "/var/tmp/cmux-iroh-gate-test.bin"
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
    func chatSessionsAcceptProductWireDates() throws {
        let descriptor = ChatSessionDescriptor(
            id: "release-gate-session",
            agentKind: .codex,
            title: "Iroh release gate",
            workspaceID: "workspace",
            terminalID: "terminal",
            workingDirectory: "/tmp",
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 1_784_432_789)
        )
        let payload = try ChatWireCoding().encode(
            MobileChatSessionsResponse(sessions: [descriptor])
        )

        #expect(MobileIrohReleaseGateResponseValidator.chatSessions(payload))
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
