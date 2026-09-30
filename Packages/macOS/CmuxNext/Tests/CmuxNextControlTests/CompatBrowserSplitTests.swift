@testable import CmuxNextControl
import Foundation
import Testing

/// `cmux browser open` creates the tab in the source pane and then moves it
/// into a split. When the move is refused ("not enough room to split"), the
/// reply must match what exists: the tab in the source pane, reported as
/// such, or nothing at all with the error.
@Suite struct CompatBrowserSplitTests {
    static let refusal = ControlError(code: "unavailable", message: "tab.moveToNewSplit: not enough room to split this pane",
                                      data: ["action": .string("tab.moveToNewSplit"), "reason": .string("not enough room to split this pane")])

    final class Discards: @unchecked Sendable {
        var count = 0
    }

    @Test func refusedSplitFallsBackToATabAndSaysWhy() async throws {
        let discards = Discards()
        let placement = try await CompatCreate.moveBrowserIntoSplit(
            fallbackToTab: true, move: { throw Self.refusal }, discard: { discards.count += 1 })
        #expect(placement == .tab(reason: "not enough room to split this pane"))
        #expect(discards.count == 0)
    }

    @Test func refusedSplitWithoutFallbackOpensNothing() async {
        let discards = Discards()
        await #expect(throws: ControlError.self) {
            _ = try await CompatCreate.moveBrowserIntoSplit(
                fallbackToTab: false, move: { throw Self.refusal }, discard: { discards.count += 1 })
        }
        #expect(discards.count == 1)
    }

    @Test func otherFailuresCloseTheTabAndThrow() async {
        let discards = Discards()
        await #expect(throws: ControlError.self) {
            _ = try await CompatCreate.moveBrowserIntoSplit(
                fallbackToTab: true, move: { throw ControlError(code: "timeout", message: "late") }, discard: { discards.count += 1 })
        }
        #expect(discards.count == 1)
    }

    @Test func successfulMoveIsASplit() async throws {
        let placement = try await CompatCreate.moveBrowserIntoSplit(fallbackToTab: true, move: {}, discard: {})
        #expect(placement == .split)
    }

    @Test func openSplitReplyNamesTheFallbackPlacement() {
        let split = CompatBrowserMethods.placementFields(.split)
        #expect(split["created_split"] == true)
        #expect(split["placement_strategy"] == "split_right")
        let tab = CompatBrowserMethods.placementFields(.tab(reason: "no room"))
        #expect(tab["created_split"] == false)
        #expect(tab["placement_strategy"] == "tab")
        #expect(tab["placement_fallback_reason"] == "no room")
    }
}
