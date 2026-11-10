import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/31513: an opt-in setting moves a workspace to the top
/// of the sidebar when its agent finishes (`notifications.attention.moveToTopOnAgentFinish`). Before,
/// the only reorder was `notifications.attention.moveToTop`, which moves on every notification
/// (a bell, `cmux notify`, an agent's question or error). From cmux.json and the daemon's wire
/// notification to the decision `NotificationCenterService.moveToTop` gates on.
struct NotificationMoveToTopOnAgentFinishTests {
    static func notification(source: String, level: String) throws -> DaemonNotification {
        let wire = #"{"notification":3,"title":"Claude finished","body":"","level":"\#(level)","source":"\#(source)"}"#
        return try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))
    }

    static func attention(_ members: [String: CmuxNextSettings.JSONValue]) -> AttentionSettings {
        let root: CmuxNextSettings.JSONValue = .object(["notifications": .object(["attention": .object(members)])])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).attention
    }

    static func moves(_ settings: AttentionSettings, _ notification: DaemonNotification) -> Bool {
        settings.movesToTop(finishedTurn: notification.isFinishedTurn)
    }

    @Test func onlyAnAgentsFinishedTurnMovesItsWorkspaceWithTheSettingOn() throws {
        let settings = Self.attention(["moveToTop": .bool(false), "moveToTopOnAgentFinish": .bool(true)])
        #expect(Self.moves(settings, try Self.notification(source: "agent", level: "info")), "a finished agent did not move its workspace")
        #expect(!Self.moves(settings, try Self.notification(source: "agent", level: "warning")), "an agent's question moved its workspace")
        #expect(!Self.moves(settings, try Self.notification(source: "agent", level: "error")), "an agent's error moved its workspace")
        #expect(!Self.moves(settings, try Self.notification(source: "cli", level: "info")), "a cmux notify moved its workspace")
        #expect(!Self.moves(settings, try Self.notification(source: "terminal", level: "info")), "a terminal bell moved its workspace")
    }

    /// The user, 2026-11-09: "we should move workspaces that have notifications to top like imessage
    /// (if it is off, we need to make it on by default)". Every notification moves its workspace by
    /// default; `moveToTop: false` keeps the order the user made, and the finished-turn opt-in still works.
    @Test func everyNotificationMovesItsWorkspaceByDefaultAndTheSettingTurnsItOff() throws {
        let finished = try Self.notification(source: "agent", level: "info")
        let bell = try Self.notification(source: "terminal", level: "info")
        let question = try Self.notification(source: "agent", level: "warning")
        let defaults = Self.attention([:])
        #expect(Self.moves(defaults, finished) && Self.moves(defaults, bell) && Self.moves(defaults, question),
                "a default sidebar did not move a notified workspace to the top")
        #expect(AttentionSettings().movesToTop, "AttentionSettings() does not move on a notification")
        let row = try #require(SettingsSchema.descriptor(for: ["notifications", "attention", "moveToTop"]), "no settings row")
        #expect(row.defaultValue == .bool(true))
        let off = Self.attention(["moveToTop": .bool(false)])
        #expect(!Self.moves(off, finished) && !Self.moves(off, bell), "moveToTop false still reordered the sidebar")
        let finishOnly = Self.attention(["moveToTop": .bool(false), "moveToTopOnAgentFinish": .bool(true)])
        #expect(Self.moves(finishOnly, finished) && !Self.moves(finishOnly, bell))
    }
}
