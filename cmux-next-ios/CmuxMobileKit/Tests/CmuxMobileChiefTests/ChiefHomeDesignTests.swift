import CmuxConversationCore
import CmuxMobileModel
import Foundation
import Testing
#if os(iOS)
import SwiftUI
#endif
@testable import CmuxMobileChief

/// The Home and Chief design pass (verify/design/home-chief/SPEC.md).
@Suite struct ChiefEngineReportDesignTests {
    private func report(_ result: String) throws -> ChiefEngineReport {
        let line = #"{"protocol":"cmux.protocol/2","type":"response","id":"r1","ok":true,"result":"# + result + "}"
        return try ChiefControl.decode(Data(line.utf8), mutation: false)
    }

    /// SPEC 2: the Mac's avatar text when its reply has one; today's Macs
    /// send no `avatar` key, so the phone keeps "C" and offers no Avatar row.
    @Test func avatarComesFromTheMacWhenItSendsOne() throws {
        let today = try report(#"{"engine":{"harness":"codex"}}"#)
        #expect(!today.avatarSupported)
        #expect(today.avatar == nil)
        let set = try report(#"{"engine":{"harness":"codex"},"avatar":"🦊"}"#)
        #expect(set.avatarSupported)
        #expect(set.avatar == "🦊")
        let empty = try report(#"{"engine":{"harness":"codex"},"avatar":null}"#)
        #expect(empty.avatarSupported)
        #expect(empty.avatar == nil)
        // A picture's file name is not avatar text.
        #expect(try report(#"{"engine":{},"avatar":"cat.png"}"#).avatar == nil)
        #expect(ChiefEngineReport.avatarText("  AB  ") == "AB")
        // F7: anything that looks like a file is not text.
        for file in ["avatar.png", "Cat.JPG", "me.webp", "pics/a", "x.gif"] {
            #expect(ChiefEngineReport.avatarText(file) == nil)
        }
        #expect(ChiefEngineReport.avatarText(nil) == nil)
        #expect(try report(#"{"engine":{},"avatar":{"picture":"a.png"}}"#).avatar == nil)
        #expect(ChiefEngineReport.avatarText("ABC") == "AB")
    }

    /// The live Codex report of 10-13 (an older Mac): no resolved model.
    static func olderMacCodex() throws -> ChiefEngineReport {
        let line = #"{"protocol":"cmux.protocol/2","type":"response","id":"r1","ok":true,"result":{"engine":{"harness":"codex","model":null,"effort":"high"},"choice":{"harness":"codex","effort":"high"},"recent":[{"harness":"claude","status":"error","ms":177000}],"offered":{"models":[{"id":"default","name":"Default"},{"id":"gpt-6.1-sol","name":"GPT-6.1 Sol"}],"efforts":["low","high"]}}}"#
        return try ChiefControl.decode(Data(line.utf8), mutation: false)
    }

    /// The same Chief on a #20531 Mac.
    static func newMacCodex() throws -> ChiefEngineReport {
        let line = #"{"protocol":"cmux.protocol/2","type":"response","id":"r1","ok":true,"result":{"engine":{"harness":"codex","model":"gpt-6.1-sol","model_is_default":true,"effort":"high"},"choice":{"harness":"codex","effort":"high"},"avatar":null,"recent":[],"offered":{"models":[{"id":"default","name":"Default (GPT-6.1 Sol)","resolves_to":"gpt-6.1-sol"},{"id":"gpt-6.1-sol","name":"GPT-6.1 Sol","catalog_default":true}],"default_model":{"id":"gpt-6.1-sol","name":"GPT-6.1 Sol"},"efforts":["low","high"]}}}"#
        return try ChiefControl.decode(Data(line.utf8), mutation: false)
    }

    /// F1: the #20531 fields decode; the older shape still does.
    @Test func resolvedDefaultDecodes() throws {
        let new = try Self.newMacCodex()
        #expect(new.engine.modelIsDefault == true)
        #expect(new.offered.defaultModel == .init(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"))
        #expect(new.defaultEntry?.resolvesTo == "gpt-6.1-sol")
        #expect(new.resolvedDefaultName == "GPT-6.1 Sol")
        #expect(new.avatarSupported)
        let old = try Self.olderMacCodex()
        #expect(old.engine.modelIsDefault == nil)
        #expect(old.resolvedDefaultName == nil)
        #expect(!old.avatarSupported)
    }

    /// SPEC 4: acpmux's "default" model entry names what it resolves to and
    /// is not listed twice.
    @Test func defaultModelEntryIsSeparate() throws {
        let got = try report(#"{"engine":{"harness":"codex"},"offered":{"models":[{"id":"default","name":"Default (GPT-6.1 Sol)"},{"id":"gpt-6.1-sol","name":"GPT-6.1 Sol"}]}}"#)
        #expect(got.defaultEntry?.name == "Default (GPT-6.1 Sol)")
        #expect(got.pickableModels.map(\.id) == ["gpt-6.1-sol"])
        #expect(got.modelName("gpt-6.1-sol") == "GPT-6.1 Sol")
        #expect(got.modelName("default") == nil)
        #expect(got.modelName(nil) == nil)
    }
}

@Suite struct ChiefAvatarIdentityTests {
    /// SPEC 2: Chief's header avatar is its avatar text, not initials of its name.
    @Test func chiefParticipantUsesAvatarText() {
        let identity = ChiefIdentity(avatar: "🦊")
        #expect(identity.chief.initials == "🦊")
        let wire = ChiefWire(identity: identity)
        let info = wire.info(["id": "c1", "participants": [
            ["id": "user_local", "display_name": "You"],
            ["id": "agent_mux", "display_name": "Chief Of Staff"],
        ]])
        #expect(info?.participants.first { $0.id == "agent_mux" }?.initials == "🦊")
        #expect(ChiefIdentity.standard.chief.initials == "C")
    }

    #if DEBUG
    /// SPEC 7: every seeded reply is later than the message it answers.
    @Test func mockSeedIsInOrder() {
        let messages = ChiefMockScript.history(identity: .standard, now: Date())
        #expect(zip(messages, messages.dropFirst()).allSatisfy { $0.sentAt < $1.sentAt })
    }
    #endif
}

@Suite @MainActor struct ChiefSessionHomeStateTests {
    /// SPEC 1.6: Needs You and the pin's preview follow the outbox.
    @Test func outboxMeansChiefWaitsOnYou() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
        let session = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: file))
        #expect(!session.needsYou)
        #expect(!session.isWaitingOnYou)
        session.send(ConversationComposeMessage(text: "status?"))
        #expect(session.needsYou)
        #expect(session.isWaitingOnYou)
        session.discardOutbox()
        #expect(!session.needsYou)
        // F6: waiting on you (a question not yet seen) counts as Needs You,
        // as the pin's bubble shows it; covered with the mock below.
        #expect(session.avatar == "C")
    }

    #if DEBUG
    /// F6: Chief's unseen question shows on the pin and counts as Needs You.
    @Test func unseenQuestionIsNeedsYou() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
        let preferences = ChiefPreferences(defaults: try #require(UserDefaults(suiteName: "chief-seen-\(UUID().uuidString)")))
        let session = ChiefSession(backend: ChiefMockBackend(sleep: { _ in }), preferences: preferences, outbox: ChiefOutbox(file: file))
        try await waitUntil("Chief's first message") { session.lastMessage != nil }
        #expect(session.isWaitingOnYou)
        #expect(session.needsYou)
        session.markSeen()
        #expect(!session.isWaitingOnYou)
        // QA 2026-10-27: after a relaunch the question seen before stays seen
        // (the marker was in memory only, so every old question came back).
        let relaunched = ChiefSession(backend: ChiefMockBackend(sleep: { _ in }), preferences: preferences, outbox: ChiefOutbox(file: file))
        try await waitUntil("Chief's first message after a relaunch") { relaunched.lastMessage != nil }
        #expect(!relaunched.isWaitingOnYou)
    }
    #endif
}

#if os(iOS)
@Suite @MainActor struct HomeDesignTests {
    /// SPEC 4: recent turns read as words, never raw ids.
    @Test func recentTurnsAreReadable() {
        let report = ChiefEngineReport(engine: .init(harness: "codex"),
                                       offered: .init(models: [.init(id: "opus", name: "Claude Opus")]))
        var turn = ChiefEngineReport.Turn()
        turn.harness = "claude"
        turn.status = "error"
        turn.ms = 177_000
        turn.tools = 3
        turn.costUSD = 0.04
        #expect(ChiefSettingsView.turnTitle(turn, in: report) == "Claude")
        turn.model = "opus"
        #expect(ChiefSettingsView.turnTitle(turn, in: report) == "Claude Opus")
        #expect(ChiefSettingsView.turnLine(turn) == "Failed · 2 min 57 s · 3 tools · $0.04")
        #expect(ChiefSettingsView.durationText(milliseconds: 45_000) == "45 s")
    }

    /// F1: a #20531 Mac resolves the default; an older Mac gets plain "Default".
    @Test func defaultModelLabelNamesTheModel() throws {
        #expect(ChiefSettingsView.defaultModelLabel(try ChiefEngineReportDesignTests.newMacCodex()) == "Default (GPT-6.1 Sol)")
        // Only `resolves_to` on the entry.
        let entry = ChiefEngineReport(engine: .init(harness: "codex"),
                                      offered: .init(models: [.init(id: "default", name: "Default (GPT-6.1 Sol)", resolvesTo: "gpt-6.1-sol"),
                                                              .init(id: "gpt-6.1-sol", name: "GPT-6.1 Sol")]))
        #expect(ChiefSettingsView.defaultModelLabel(entry) == "Default (GPT-6.1 Sol)")
        // Only `engine.model` with `model_is_default`.
        let resolved = ChiefEngineReport(engine: .init(harness: "claude", model: "opus", modelIsDefault: true),
                                         offered: .init(models: [.init(id: "opus", name: "Claude Opus")]))
        #expect(ChiefSettingsView.defaultModelLabel(resolved) == "Default (Claude Opus)")
        // The 10-13 live report from an older Mac: no name to give.
        let old = try ChiefEngineReportDesignTests.olderMacCodex()
        #expect(ChiefSettingsView.defaultModelLabel(old) == "Default")
        // An older Mac's chosen model is not "the default".
        let chosen = ChiefEngineReport(engine: .init(harness: "claude", model: "opus"),
                                       offered: .init(models: [.init(id: "opus", name: "Claude Opus")]))
        #expect(ChiefSettingsView.defaultModelLabel(chosen) == "Default")
    }

    /// F2: no Swift error dumps on the page.
    @Test func errorsAreSentences() {
        struct Weird: Error {}
        #expect(ChiefSettingsView.errorText(Weird(), doing: .change) == "Chief on your Mac didn't take the change. Try again.")
        #expect(ChiefSettingsView.errorText(Weird(), doing: .stop) == "Chief on your Mac didn't stop. Try again.")
        let refused = ChiefControlError(code: "operation.failed", reason: "not_configured", message: "x")
        #expect(ChiefSettingsView.errorText(refused, doing: .change) == refused.description)
        let avatar = ChiefControlError(code: "invalid_avatar", reason: nil, message: "avatar too long: 17")
        #expect(ChiefSettingsView.errorText(avatar, doing: .change) == "Use an emoji or one or two letters.")
    }

    /// F4: the pin's bubble and label lose Markdown like the rows.
    @Test func pinPreviewIsPlain() {
        #expect(plainPreview("Heads up: run `cargo test -p cmux-mobile-link`. **Allow** it?") == "Heads up: run cargo test -p cmux-mobile-link. Allow it?")
    }
}

struct EmptyToolbar: ToolbarContent {
    var body: some ToolbarContent { ToolbarItem { EmptyView() } }
}
#endif
