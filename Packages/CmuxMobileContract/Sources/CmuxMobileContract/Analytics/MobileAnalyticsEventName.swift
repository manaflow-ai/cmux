import Foundation

/// The set of analytics event names the mobile client reports to the backend.
public enum MobileAnalyticsEventName: String, Codable, Equatable, Sendable {
    /// A mobile machine session was issued.
    case mobileMachineSessionIssued = "mobile_machine_session_issued"

    /// A mobile heartbeat was ingested.
    case mobileHeartbeatIngested = "mobile_heartbeat_ingested"

    /// A mobile workspace snapshot was ingested.
    case mobileWorkspaceSnapshotIngested = "mobile_workspace_snapshot_ingested"

    /// A mobile workspace was opened.
    case mobileWorkspaceOpened = "mobile_workspace_opened"

    /// A mobile workspace was marked read.
    case mobileWorkspaceMarkRead = "mobile_workspace_mark_read"

    /// A mobile push token was registered.
    case mobilePushRegistered = "mobile_push_registered"

    /// A mobile push token was removed.
    case mobilePushRemoved = "mobile_push_removed"

    /// A mobile test push was sent.
    case mobilePushTestSent = "mobile_push_test_sent"

    /// A mobile push notification was opened.
    case mobilePushOpened = "mobile_push_opened"

    /// A mobile daemon ticket was issued.
    case mobileDaemonTicketIssued = "mobile_daemon_ticket_issued"

    /// A mobile daemon attach attempt produced a result.
    case mobileDaemonAttachResult = "mobile_daemon_attach_result"

    /// The iOS GRDB database finished booting.
    case iosGRDBBootCompleted = "ios_grdb_boot_completed"
}
