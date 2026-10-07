import Foundation
import Testing
@testable import CmuxNextDaemon

/// `notification-program-status-v1`: a notification the daemon posts for an
/// OSC 7501 record that entered `blocked` or `error` carries the structured
/// reason, so the app shows the body in the user's language. Older daemons
/// send none, and the English title and body stay the fallback.
struct NotificationProgramStatusTests {
    private struct NotANotification: Error {}

    private static func event(_ json: String) throws -> DaemonNotification {
        guard case .notification(let event) = DaemonEvent.decode(name: "notification", line: Data(json.utf8)) else {
            throw NotANotification()
        }
        return event
    }

    @Test func theEventCarriesTheProgramStatus() throws {
        let blocked = try Self.event(#"{"event":"notification","notification":7,"title":"terraform","body":"Needs approval: Apply?","level":"warning","surface":3,"source":"terminal","program_status":{"state":"blocked","kind":"permission","msg":"Apply?"}}"#)
        #expect(blocked.programStatus == NotificationProgramStatus(state: .blocked, kind: .permission, msg: "Apply?"))
        #expect(blocked.title == "terraform")
        #expect(blocked.body == "Needs approval: Apply?")

        let failed = try Self.event(#"{"event":"notification","notification":8,"title":"make","body":"Failed","level":"error","surface":3,"source":"terminal","program_status":{"state":"error","kind":null,"msg":null}}"#)
        #expect(failed.programStatus == NotificationProgramStatus(state: .error, kind: nil, msg: nil))
    }

    @Test func olderDaemonsAndUnknownShapesKeepTheEnglishBody() throws {
        let old = try Self.event(#"{"event":"notification","notification":9,"title":"t","body":"b","level":"info","surface":null}"#)
        #expect(old.programStatus == nil)
        // A state this app does not know: no reason, the daemon's body shows.
        let unknown = try Self.event(#"{"event":"notification","notification":10,"title":"t","body":"b","level":"info","surface":null,"program_status":{"state":"paused","kind":null,"msg":null}}"#)
        #expect(unknown.programStatus == nil)
        #expect(unknown.body == "b")
        // A kind this app does not know reads as no kind.
        let kind = try Self.event(#"{"event":"notification","notification":11,"title":"t","body":"b","level":"info","surface":null,"program_status":{"state":"blocked","kind":"payment","msg":"m"}}"#)
        #expect(kind.programStatus == NotificationProgramStatus(state: .blocked, kind: nil, msg: "m"))
    }

    @Test func listNotificationsEntriesCarryTheProgramStatus() throws {
        let json = #"{"notifications":[{"id":"notification_1","title":"make","body":"Failed: exit 2","level":"error","terminal_id":null,"surface":null,"created_at_ms":5,"source":"terminal","acknowledged":false,"program_status":{"state":"error","kind":null,"msg":"exit 2"}},{"id":"notification_2","title":"plain","body":"","level":"info","created_at_ms":4,"acknowledged":true}]}"#
        let response = try JSONDecoder().decode(ListNotificationsRequest.Response.self, from: Data(json.utf8))
        #expect(response.notifications.count == 2)
        #expect(response.notifications[0].programStatus == NotificationProgramStatus(state: .error, kind: nil, msg: "exit 2"))
        #expect(response.notifications[1].programStatus == nil)
    }

    @Test func theCapabilityIsOptional() {
        let capabilities = DaemonCapabilities.shared
        #expect(capabilities.notificationProgramStatus == "notification-program-status-v1")
        #expect(capabilities.optional.contains(capabilities.notificationProgramStatus))
        #expect(!capabilities.required.contains(capabilities.notificationProgramStatus))
    }
}
