import AppKit
@testable import CmuxNextApp
import Foundation
import Testing
import CmuxNextFilesUI
import CmuxNextWakeupsTestSupport

/// The Find section searches while the person types: a pause in typing starts one search for the
/// last text, typing again cancels the waiting or running search, and a cancelled search's answer
/// never shows.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct FindLiveSearchTests {
    static let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
    static func match(_ preview: String) -> RipgrepMatch {
        RipgrepMatch(path: "/tmp/project/a.txt", relativePath: "a.txt", line: 1, column: 1, preview: preview)
    }

    @Test func typingSearchesOnceForTheLastTextAfterThePause() async throws {
        let clock = ManualClock()
        var asked: [String] = []
        let model = FindSectionModel(search: { query, _ in
            asked.append(query)
            return .matches([Self.match(query)], limited: false)
        }, clock: clock)
        model.setRoot(Self.root)
        model.type("ne")
        model.type("nee")
        model.type("needle")
        try await clock.waitForSleeper()
        #expect(asked.isEmpty, "a search ran before the pause")
        clock.advance(by: FindSectionModel.debounce)
        await model.pendingSearch?.value
        #expect(asked == ["needle"])
        #expect(model.results == [Self.match("needle")])
    }

    @Test func typingAgainCancelsARunningSearchAndItsAnswerNeverShows() async throws {
        let clock = ManualClock()
        var release: CheckedContinuation<Void, Never>?
        var cancelled: [String] = []
        let model = FindSectionModel(search: { query, _ in
            if query == "old" {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { release = $0 }
                } onCancel: {}
                if Task.isCancelled { cancelled.append(query) }
            }
            return .matches([Self.match(query)], limited: false)
        }, clock: clock)
        model.setRoot(Self.root)
        model.type("old")
        try await clock.waitForSleeper()
        clock.advance(by: FindSectionModel.debounce)
        while release == nil { await Task.yield() }
        let running = model.pendingSearch
        model.type("new")
        release?.resume()
        await running?.value
        #expect(cancelled == ["old"], "typing again did not cancel the running search")
        #expect(model.results.isEmpty, "the cancelled search's answer showed")
        try await clock.waitForSleeper()
        clock.advance(by: FindSectionModel.debounce)
        await model.pendingSearch?.value
        #expect(model.results == [Self.match("new")])
    }

    @Test func returnSearchesAtOnceAndDropsTheWaitingSearch() async throws {
        let clock = ManualClock()
        var asked: [String] = []
        let model = FindSectionModel(search: { query, _ in
            asked.append(query)
            return .matches([], limited: false)
        }, clock: clock)
        model.setRoot(Self.root)
        model.type("nee")
        try await clock.waitForSleeper()
        await model.search("needle")
        clock.advance(by: FindSectionModel.debounce)
        await model.pendingSearch?.value
        #expect(asked == ["needle"])
    }
}
