import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The Chief's status line ("Telling a31 · 4s"): it heads the typing dots, and a
/// click lists the turn's steps so far with their durations.
@MainActor @Suite struct HomeTurnStatusTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func state(typing: Bool, notice: String?) -> AppState {
        var s = AppState(conversation: Conversation(id: "c", title: "Chief", participants: [
            Participant(id: "me", displayName: "Me", isMe: true, avatar: nil),
            Participant(id: "chief", displayName: "Chief", isMe: false, avatar: nil),
        ], messages: []))
        if typing { s.ui.typing = ["chief"] }
        s.ui.notice = notice
        return s
    }

    @Test func theStatusLineSitsAboveTheTypingIndicator() throws {
        let keys = RowBuilder.rows(Self.state(typing: true, notice: "Telling a31 · 1s"), messages: [], now: Self.t0).map { $0.key }
        let line = try #require(keys.firstIndex(of: "notice"))
        let dots = try #require(keys.firstIndex(of: "typing"))
        #expect(line < dots, "rows: \(keys)")
    }

    @Test func theStatusLineShowsWithoutTypingToo() {
        let keys = RowBuilder.rows(Self.state(typing: false, notice: "Thinking"), messages: [], now: Self.t0).map { $0.key }
        #expect(keys.contains("notice"))
        #expect(!keys.contains("typing"))
    }

    @Test func theChiefFootnoteHasHomeSpacingUnderTheSwitchingCard() throws {
        var state = Self.state(typing: false, notice: nil)
        state.ui.cmuxNotice = "Chief memory summaries are paused. The Chief still answers."
        let row = try #require(RowBuilder.rows(state, messages: [], now: Self.t0).first { $0.key == "notice" })
        #expect(row.gap == 8)
    }

    @Test func stepsRunFromOneLineToTheNext() {
        var steps = HomeTurnSteps()
        steps.record(HomeLiveActivity(line: "Thinking", since: Self.t0))
        steps.record(HomeLiveActivity(line: "Telling an agent", since: Self.t0.addingTimeInterval(3)))
        // The same call's input arrived: a sharper line, the same start, still one step.
        steps.record(HomeLiveActivity(line: "Telling a31", since: Self.t0.addingTimeInterval(3)))
        let details = steps.details(now: Self.t0.addingTimeInterval(10))
        #expect(details.steps == [
            .init(line: "Thinking", duration: 3, running: false),
            .init(line: "Telling a31", duration: 7, running: true),
        ])
        #expect(details.total == 10)
    }

    @Test func anOlderStartBeginsANewTurn() {
        var steps = HomeTurnSteps()
        steps.record(HomeLiveActivity(line: "Reading notes.md", since: Self.t0.addingTimeInterval(60)))
        steps.record(HomeLiveActivity(line: "Thinking", since: Self.t0))
        let details = steps.details(now: Self.t0.addingTimeInterval(2))
        #expect(details.steps.map(\.line) == ["Thinking"])
        #expect(details.total == 2)
    }

    @Test func theLineKeepsTheTurnsStepsUntilItCloses() throws {
        var now = Self.t0
        let line = HomeLiveLine(now: { now })
        var shown: [String?] = []
        line.dispatch = { shown.append($0) }
        #expect(line.details() == nil)
        line.show(HomeLiveActivity(line: "Thinking", since: Self.t0))
        now = Self.t0.addingTimeInterval(2)
        line.show(HomeLiveActivity(line: "List files", since: now))
        now = Self.t0.addingTimeInterval(5)
        let details = try #require(line.details())
        #expect(details.steps.map(\.line) == ["Thinking", "List files"])
        #expect(details.steps.last?.duration == 3)
        #expect(details.total == 5)
        line.stop()
    }

    @Test func durationsReadShort() {
        #expect(HomeTurnStatusView.duration(0.4) == CmuxStrings.turnUnderOneSecond)
        #expect(HomeTurnStatusView.duration(65) == HomeLiveLine.elapsed(65))
        #expect(HomeLiveLine.elapsed(0.5) == nil)
    }
}
