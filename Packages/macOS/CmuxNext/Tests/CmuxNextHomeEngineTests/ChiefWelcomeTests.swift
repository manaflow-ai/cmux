import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The Chief's first-launch welcome (#26053): one message from the Chief in its own conversation,
/// on the first launch on this Mac only, never into a conversation that already has history.
@MainActor @Suite struct ChiefWelcomeTests {
    private static let shortcuts = [
        ChiefWelcome.Shortcut(keys: "⇧⌘P", title: "Command Palette"),
        ChiefWelcome.Shortcut(keys: "⌘T", title: "New Tab"),
    ]

    private func freshDefaults() throws -> UserDefaults {
        let suite = "chief-welcome-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func text() -> String { ChiefWelcome.text(goTo: "⌘P", shortcuts: Self.shortcuts) }

    @Test func aFreshChiefConversationGetsOneWelcomeFromTheChiefAndNeverASecond() async throws {
        let defaults = try freshDefaults()
        let welcome = ChiefWelcome(defaults: defaults, chief: "agent_mux")
        let sent = Sent()
        let step = await welcome.run(conversation: "conv_chief", lastSeq: 0, text: text) { sent.requests.append($0) }
        #expect(step == .post("conv_chief"))
        let request = try #require(sent.requests.first)
        #expect(request.conversation == "conv_chief")
        let message = try #require(request.messages.first)
        #expect(request.messages.count == 1)
        #expect(message.author == "agent_mux")
        #expect(message.clientMsgID == ChiefWelcome.clientMsgID)
        #expect(message.parts == [.object(["type": .string("text"), "text": .string(text())])])
        #expect(welcome.posted)

        // The next launch, and a later connection of the same launch, post nothing more, even
        // while the conversation still reads as empty (the owner's list can lag the import).
        let again = await ChiefWelcome(defaults: defaults, chief: "agent_mux")
            .run(conversation: "conv_chief", lastSeq: 0, text: text) { sent.requests.append($0) }
        #expect(again == .done)
        #expect(sent.requests.count == 1)
    }

    @Test func aChiefConversationWithHistoryIsNeverWelcomed() async throws {
        let defaults = try freshDefaults()
        let welcome = ChiefWelcome(defaults: defaults, chief: "agent_mux")
        let sent = Sent()
        let step = await welcome.run(conversation: "conv_chief", lastSeq: 12, text: text) { sent.requests.append($0) }
        #expect(step == .done)
        #expect(sent.requests.isEmpty)
        // Marked done: an upgrade never gets the welcome later, e.g. after the history is cleared.
        #expect(welcome.posted)
        let later = await welcome.run(conversation: "conv_chief", lastSeq: 0, text: text) { sent.requests.append($0) }
        #expect(later == .done)
        #expect(sent.requests.isEmpty)
    }

    @Test func noChiefConversationYetOrAFailedImportTriesAgainLater() async throws {
        let defaults = try freshDefaults()
        let welcome = ChiefWelcome(defaults: defaults, chief: "agent_mux")
        let sent = Sent()
        #expect(await welcome.run(conversation: nil, lastSeq: 0, text: text) { sent.requests.append($0) } == .wait)
        #expect(!welcome.posted)

        let failed = await welcome.run(conversation: "conv_chief", lastSeq: 0, text: text) { _ in throw DaemonError.notConnected }
        #expect(failed == .wait)
        #expect(!welcome.posted)

        let retried = await welcome.run(conversation: "conv_chief", lastSeq: 0, text: text) { sent.requests.append($0) }
        #expect(retried == .post("conv_chief"))
        #expect(sent.requests.count == 1)
        #expect(welcome.posted)
    }

    @Test func theTextCallsOutCommandPFirstThenTheShortcutsExamplesAndWhatToAsk() throws {
        let text = text()
        let goTo = try #require(text.range(of: "**Press `⌘P` to go anywhere.**"))
        let palette = try #require(text.range(of: "- `⇧⌘P` Command Palette"))
        let newTab = try #require(text.range(of: "- `⌘T` New Tab"))
        let examples = try #require(text.range(of: HomeStrings.chiefWelcomeExamplesHeader))
        let ask = try #require(text.range(of: HomeStrings.chiefWelcomeAsk))
        #expect(text.hasPrefix(HomeStrings.chiefWelcomeIntro))
        #expect(goTo.lowerBound < palette.lowerBound && palette.lowerBound < newTab.lowerBound)
        #expect(newTab.lowerBound < examples.lowerBound && examples.lowerBound < ask.lowerBound)
        #expect(HomeStrings.chiefWelcomeAsk.contains("coding agents") && HomeStrings.chiefWelcomeAsk.contains("browsers"))
        #expect(text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count == 2 + 4)

        // An unbound Go to Workspace drops the call-out, never shows an empty key.
        let unbound = ChiefWelcome.text(goTo: nil, shortcuts: [])
        #expect(!unbound.contains("**"))
        #expect(!unbound.contains(HomeStrings.chiefWelcomeShortcuts))
    }

    @Test func theTimeIsTheOwnersFormatAndNeverInItsFuture() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000.5)
        let stamp = ChiefWelcome.timestamp(now)
        // conversation_import.rs `valid_time`: YYYY-MM-DDTHH:MM:SS.mmmZ.
        #expect(stamp.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/) != nil)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = try #require(formatter.date(from: stamp))
        #expect(parsed < now)
    }
}

/// The imports the fake owner received.
@MainActor private final class Sent {
    var requests: [ConversationImportRequest] = []
}
