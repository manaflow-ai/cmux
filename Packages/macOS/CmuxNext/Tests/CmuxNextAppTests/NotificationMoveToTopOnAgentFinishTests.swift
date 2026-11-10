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

    /// Leo 2026-11-10: "the ones that are blue that are done, I think we can probably turn that on. Likewise with the
    /// yellow, we can probably like have that go up." The every-notification setting is on by default: a finished
    /// turn (blue) and a question (yellow) move their workspace; off, nothing does.
    @Test func everyNotificationMovesByDefaultAndTheAgentFinishSettingIsOptIn() throws {
        let finished = try Self.notification(source: "agent", level: "info")
        let question = try Self.notification(source: "agent", level: "warning")
        let defaults = Self.attention([:])
        #expect(Self.moves(defaults, finished) && Self.moves(defaults, question), "a default sidebar did not move a done or needs-you workspace")
        let every = try #require(SettingsSchema.descriptor(for: ["notifications", "attention", "moveToTop"]), "no settings row")
        #expect(every.defaultValue == .bool(true))
        let row = try #require(SettingsSchema.descriptor(for: ["notifications", "attention", "moveToTopOnAgentFinish"]), "no settings row")
        #expect(row.defaultValue == .bool(false))
        let off = Self.attention(["moveToTop": .bool(false)])
        #expect(!Self.moves(off, finished) && !Self.moves(off, question), "a sidebar with the setting off reordered on a notification")
    }
}
