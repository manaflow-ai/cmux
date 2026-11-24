import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// The phone's reader of acpmux's `composerStatus` (RFD 0130): it keeps acpmux's order and live
/// marks, drops what it does not know, and never draws a raw catalog key.
@Suite struct AgentComposerStatusTests {
    private static let wire: JSONValue = .object([
        "items": .array([
            .object(["kind": .string("stuck"), "level": .string("problem"), "words": .string("status.stuck.auth"),
                     "subject": .string("Claude Code"), "since": .number(1_000)]),
            .object(["kind": .string("future"), "level": .string("problem"), "words": .string("status.future.thing")]),
            .object(["kind": .string("rateLimited"), "level": .string("severe"), "words": .string("status.rateLimited.parked")]),
            .object(["kind": .string("machineLink"), "level": .string("info"), "words": .string("status.machineLink.reconnecting"),
                     "subject": .string("mini-3"), "showAt": .number(5_000)]),
        ]),
        "facts": .array([
            .object(["kind": .string("folder"), "text": .string("/Users/leo/Projects/cmux"), "live": .bool(false)]),
            .object(["kind": .string("context"), "fraction": .number(1.7), "live": .bool(false)]),
            .object(["kind": .string("subagents"), "count": .number(12), "live": .bool(true)]),
            .object(["kind": .string("queued"), "count": .number(2), "live": .bool(false)]),
            .object(["kind": .string("weather"), "text": .string("sunny"), "live": .bool(true)]),
        ]),
    ])

    @Test func readsTheWireAndDropsTheUnknown() throws {
        let status = try #require(AgentComposerStatus(json: Self.wire))
        // An unknown level is dropped; an unknown kind with unknown words is kept but never drawn.
        #expect(status.items.map(\.kind) == ["stuck", "future", "machineLink"])
        #expect(status.facts.map(\.kind) == [.folder, .context, .subagents, .queued])
        #expect(status.facts[1].fraction == 1)
        #expect(status.items[0].text == "Sign in to Claude Code")
        #expect(status.items[1].text == nil)
    }

    @Test func showsOnlyDueItemsItsBuildKnows() throws {
        let status = try #require(AgentComposerStatus(json: Self.wire))
        #expect(status.shownItems(at: Date(timeIntervalSince1970: 4)).map(\.kind) == ["stuck"])
        #expect(status.shownItems(at: Date(timeIntervalSince1970: 5)).map(\.kind) == ["stuck", "machineLink"])
    }

    @Test func countersFollowAcpmuxsLiveMark() throws {
        let status = try #require(AgentComposerStatus(json: Self.wire))
        #expect(status.liveCount(.subagents) == 12)
        #expect(status.liveCount(.queued) == nil)
        #expect(AgentComposerStatus.counterText(12) == "9+")
        #expect(AgentComposerStatus.counterText(3) == "3")
    }

    @Test func folderShowsItsLastTwoSegments() throws {
        let status = try #require(AgentComposerStatus(json: Self.wire))
        #expect(status.facts[0].value(at: .now) == "Projects/cmux")
    }

    @Test func anOlderAcpmuxSendsNothing() {
        #expect(AgentComposerStatus(json: nil) == nil)
        #expect(AgentComposerStatus(json: .null) == nil)
        #expect(AgentComposerStatus(json: .object(["items": .array([])])) == nil)
    }

    @Test func unknownArmReadsAsOff() {
        #expect(ComposerFooterFactsArm(stored: "strip") == .off)
        #expect(ComposerFooterFactsArm(stored: "pulse") == .pulse)
        #expect(ComposerFooterFactsArm.defaultArm == .off)
    }
}
