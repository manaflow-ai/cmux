@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// A window saved in full screen (the record's `full_screen`, written on
/// every save) asks to enter full screen again after a relaunch, such as
/// the relaunch of every app update; a windowed one does not.
@MainActor
struct WindowFullScreenRestoreTests {
    @Test func aWindowSavedInFullScreenReturnsToFullScreen() throws {
        let fullScreen = try Self.state(#"{"id":"w1","workspace_key":"ws-a","full_screen":true}"#)
        #expect(fullScreen.restoresFullScreen, "the saved full screen state was dropped")
        let windowed = try Self.state(#"{"id":"w2","workspace_key":"ws-b","full_screen":false}"#)
        #expect(!windowed.restoresFullScreen)
    }

    private static func state(_ saved: String) throws -> WindowState {
        let decoded = try JSONDecoder().decode(WindowRecord.self, from: Data(saved.utf8))
        return WindowState(record: try JSONDecoder().decode(WindowRecord.self, from: JSONEncoder().encode(decoded)))
    }
}
