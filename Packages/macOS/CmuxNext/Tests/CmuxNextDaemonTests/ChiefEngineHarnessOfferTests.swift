import Foundation
import Testing
@testable import CmuxNextDaemon

/// The engines `chief.engine.get` offers the Chief picker (`offered.harnesses`,
/// optchat-chief brain/harness_offer.rs): each with its name, family, what it
/// supports and why it cannot run when it cannot.
struct ChiefEngineHarnessOfferTests {
    static let answer = Data(#"""
    {"engine": {"harness": "claude-sr"}, "offered": {"models": [], "efforts": [], "speeds": ["default"], "harnesses": [
      {"id": "codex", "displayName": "Codex", "family": "codex", "chiefFamily": "codex", "kind": "acp",
       "capabilities": {"efforts": ["minimal", "low", "medium", "high", "xhigh", "max"], "speeds": ["default", "fast"]},
       "unavailable": false},
      {"id": "opencode", "displayName": "OpenCode", "family": "opencode", "chiefFamily": "other", "kind": "acp",
       "capabilities": {"efforts": ["low", "high"], "speeds": ["default"], "resume": true, "permissionModes": true},
       "unavailable": true, "unavailableReason": "acpmux's opencode is unavailable: opencode is not on PATH",
       "icon": "opencode", "login": "opencode auth login"},
      {"id": "unii", "displayName": "UniiChat", "family": "unii", "chiefFamily": "other", "kind": "acp",
       "capabilities": {"efforts": ["minimal"], "speeds": ["default"], "resume": true, "someFutureFlag": 3},
       "unavailable": false, "description": "UniiChat: one chat that never ends (uniichat.com)",
       "someFutureField": {"x": 1}},
      {"id": 7}
    ]}}
    """#.utf8)

    @Test func everyOfferedEngineDecodesWithWhatItSupports() throws {
        let offer = try JSONDecoder().decode(ChiefEngineHarnessOffer.self, from: Self.answer)
        #expect(offer.harnesses.map(\.id) == ["codex", "opencode", "unii"])

        let codex = try #require(offer.harness(id: "codex"))
        #expect(codex.displayName == "Codex")
        #expect(codex.family == "codex")
        #expect(codex.chiefFamily == "codex")
        #expect(codex.isAvailable)
        #expect(codex.unavailableReason == nil)
        #expect(codex.capabilities.speeds == ["default", "fast"])
        #expect(codex.capabilities.efforts.count == 6)
        #expect(codex.capabilities.resume == nil)

        let opencode = try #require(offer.harness(id: "opencode"))
        #expect(!opencode.isAvailable)
        #expect(opencode.unavailableReason?.contains("not on PATH") == true)
        #expect(opencode.capabilities.efforts == ["low", "high"])
        #expect(opencode.capabilities.resume == true)
        #expect(opencode.capabilities.permissionModes == true)
        #expect(opencode.login == "opencode auth login")
        #expect(opencode.icon == "opencode")

        let unii = try #require(offer.harness(id: "unii"))
        #expect(unii.family == "unii")
        #expect(unii.chiefFamily == "other")
        #expect(unii.description == "UniiChat: one chat that never ends (uniichat.com)")
    }

    /// The picker lists the engines that can run a turn first, in the brain's order.
    @Test func thePickerOrderPutsAvailableEnginesFirst() throws {
        let offer = try JSONDecoder().decode(ChiefEngineHarnessOffer.self, from: Self.answer)
        #expect(offer.pickerOrder.map(\.id) == ["codex", "unii", "opencode"])
    }

    /// An older brain answers no `harnesses`: the picker keeps its own list.
    @Test func anOlderBrainOffersNone() throws {
        let old = Data(#"{"engine": {"harness": "claude"}, "offered": {"models": [], "efforts": [], "speeds": []}}"#.utf8)
        #expect(try JSONDecoder().decode(ChiefEngineHarnessOffer.self, from: old).harnesses.isEmpty)
        let older = Data(#"{"engine": {"harness": "claude"}}"#.utf8)
        #expect(try JSONDecoder().decode(ChiefEngineHarnessOffer.self, from: older).harnesses.isEmpty)
    }

    /// A row without a reason still reads as unavailable when the brain says so.
    @Test func anUnavailableRowWithoutAReasonIsStillUnavailable() throws {
        let row = Data(#"""
        {"id": "pi", "displayName": "Pi", "family": "pi", "chiefFamily": "other", "kind": "acp",
         "capabilities": {"efforts": [], "speeds": ["default"]}, "unavailable": true}
        """#.utf8)
        let pi = try JSONDecoder().decode(ChiefEngineHarness.self, from: row)
        #expect(!pi.isAvailable)
        #expect(pi.unavailableReason == nil)
    }
}
