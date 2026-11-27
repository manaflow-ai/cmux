#if os(iOS)
import CmuxMobileNotifications
import Testing
@testable import CmuxMobileShell

@Suite struct CloudNotificationRouteTests {
    @Test func aCloudPushNeverBecomesAnUnscopedLocalSessionRoute() throws {
        let info: [AnyHashable: Any] = ["cmux": ["cloud": [
            "kind": "permission", "event_id": "event-1", "machine_id": "vm-1",
            "session_id": "shared-id", "team_id": "team-1",
        ]]]
        let route = try #require(NotificationRoute(userInfo: info))
        #expect(route.kind == "cloud")
        #expect(route.cloud?.machineID == "vm-1")
        #expect(route.cloud?.sessionID == "shared-id")
        #expect(route.cloud?.teamID == "team-1")
        #expect(route.sessionID == nil)
        #expect(route.mac == nil)
        #expect(route.link == nil)
    }
}
#endif
