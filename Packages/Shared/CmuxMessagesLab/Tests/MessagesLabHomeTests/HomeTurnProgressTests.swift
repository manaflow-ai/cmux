@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The Chief's running indicator while a turn runs (Leo 2026-10-20: "Using optchat: control · 6m 3s"
/// with the typing dots for six minutes said nothing): the finished steps folded into one row like the
/// agent chat's "Ran 3 commands ›", the Chief's newest thought as narration, then the step running now.
@MainActor @Suite struct HomeTurnProgressTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func steps(_ lines: [String]) -> HomeTurnSteps {
        var steps = HomeTurnSteps()
        for (index, line) in lines.enumerated() {
            steps.record(HomeLiveActivity(line: line, since: t0.addingTimeInterval(Double(index) * 10)))
        }
        return steps
    }

    /// The indicator for `lines` with the raw `thought`, headlined the way the live book publishes it.
    static func progress(_ lines: [String], thought: String? = nil, style: HomeTurnProgressStyle = .narrated) -> HomeTurnProgress {
        let steps = steps(lines)
        let current = HomeLiveActivity(line: lines.last ?? "Thinking", since: t0.addingTimeInterval(Double(lines.count - 1) * 10))
        return HomeTurnProgress(steps: steps.steps, current: current, thought: thought?.thoughtHeadline,
                                now: current.since.addingTimeInterval(5), style: style)
    }

    @Test func theFirstStepReadsAsTheOneLineBefore() {
        let progress = Self.progress(["Telling a31"])
        #expect(progress.rows == ["Telling a31 · 5s"])
    }

    @Test func finishedCommandsFoldIntoOneRowAboveTheStepNow() {
        let progress = Self.progress(["Running git status", "Running git log -1", "Running swift test", "Telling a31"])
        #expect(progress.summary == CmuxStrings.turnRanCommands(3) + " ›")
        #expect(progress.current == "Telling a31 · 5s")
        #expect(progress.rows.count == 2)
    }

    @Test func kindsFoldInTheOrderTheTurnDidThem() {
        let progress = Self.progress(["Reading a.md", "Running ls", "Reading b.md", "Running pwd", "Telling a31", "Sending a message"])
        #expect(progress.summary == [CmuxStrings.turnReadFiles(2), CmuxStrings.turnRanCommands(2), "Telling a31"].joined(separator: " · ") + " ›")
    }

    @Test func genericStepsAreNeverCounted() {
        let progress = Self.progress(["Telling a31", "Starting 2 agents", "Checking on a31", "Checking on a7"])
        // No lone "›" row ("›" over "Running · 4s", user 2026-10-30): a click on the line still lists the steps.
        #expect(progress.summary == nil)
        #expect(progress.rows == [progress.current])
        let mixed = Self.progress(["Running ls", "Running pwd", "Telling a31", "Starting 2 agents", "Checking on a31"])
        #expect(mixed.summary == CmuxStrings.turnRanCommands(2) + " ›")
        for text in [progress.summary, mixed.summary].compactMap({ $0 }) {
            #expect(!text.localizedCaseInsensitiveContains("step"))
        }
    }

    @Test func planHeaderNeverCountsSteps() {
        #expect(!CmuxStrings.planHeader(steps: 6, active: 0).contains("6"))
        #expect(!CmuxStrings.planHeader(steps: 6, active: 3).localizedCaseInsensitiveContains("step"))
    }

    @Test func thinkingAndWritingAreNotSteps() {
        let progress = Self.progress(["Thinking", "Writing the reply", "Thinking", "Telling a31"])
        #expect(progress.summary == nil)
        #expect(progress.rows == ["Telling a31 · 5s"])
    }

    @Test func theChiefsReadingToolsAreNotFileReads() {
        #expect(HomeTurnProgress.kind("Reading the chat history") == .other)
        #expect(HomeTurnProgress.kind("Reading notes.md") == .reads)
        #expect(HomeTurnProgress.kind("Editing app.ts") == .edits)
        #expect(HomeTurnProgress.kind("Searching") == .searches)
    }

    @Test func theNewestThoughtNarratesBetweenTheStepsAndTheStepNow() {
        let progress = Self.progress(["Telling a31", "Checking on a31"], thought: "**Waiting for a31's tests**\n\nIt said it would run them.")
        #expect(progress.rows == ["Telling a31 ›", "Waiting for a31's tests", "Checking on a31 · 5s"])
        let steps = Self.progress(["Telling a31", "Checking on a31"], thought: "**Waiting for a31's tests**", style: .steps)
        #expect(steps.rows == ["Telling a31 ›", "Checking on a31 · 5s"])
        let line = Self.progress(["Telling a31", "Checking on a31"], thought: "**Waiting**", style: .line)
        #expect(line.rows == ["Checking on a31 · 5s"])
    }

    @Test func thePublishedHeadlineShowsAsItIs() {
        // A heading with a sentence end inside it stays whole: the indicator does not headline it again.
        let progress = Self.progress(["Telling a31", "Checking on a31"], thought: "**Checking a31. Then a7**")
        #expect(progress.narration == "Checking a31. Then a7")
        let done = Self.progress(["Telling a31", "Checking on a31"], thought: "**Done!**")
        #expect(done.narration == "Done!")
    }

    @Test func whileThinkingTheThoughtIsTheStepNow() {
        let progress = Self.progress(["Telling a31", "Thinking"], thought: "Let me look. I should check whether a31 finished")
        #expect(progress.rows == ["Telling a31 ›", "I should check whether a31 finished · 5s"])
    }

    @Test func headlinesArePlainAndShort() {
        #expect(HomeTurnProgress.headline("**First**\n\nbody\n\n**Second `step`**") == "Second step")
        #expect(HomeTurnProgress.headline("  \n ") == nil)
        let long = String(repeating: "word ", count: 40)
        let cut = try? #require(HomeTurnProgress.headline(long))
        #expect((cut?.count ?? 0) <= HomeTurnProgress.narrationLimit)
        #expect(cut?.hasSuffix("…") == true)
    }

    /// User 2026-10-29 9:01 PM: "reading/starting agents should be one line". "Reading ›" sat on its own
    /// row over "Starting agents · 7s": the status row is one line whatever the turn did, so it never
    /// grows or jumps as steps finish or a thought arrives.
    @Test func theStatusRowStaysOneLine() throws {
        var state = HomeTurnStatusTests.state(typing: true, notice: "Checking on a31 · 5s")
        let one = try #require(RowBuilder.rows(state, messages: [], now: Self.t0).first { $0.key == "notice" })
        #expect(one.height == 16)
        for notice in ["Reading ›\nStarting agents · 7s", "Ran 3 commands ›\nWaiting for a31's tests\nChecking on a31 · 5s"] {
            state.ui.notice = notice
            let row = try #require(RowBuilder.rows(state, messages: [], now: Self.t0).first { $0.key == "notice" })
            #expect(row.height == one.height)
        }
    }

    /// The one line reads the folded steps, then the step now: "Reading › Starting agents · 7s"
    /// (the "›" already parts them; a dot after it would read "› ·").
    @Test func theStepsAndTheStepNowShareOneLine() {
        let font = HomeFonts.system(ofSize: 11)
        let notice = "Reading ›\nStarting agents · 7s"
        #expect(HomeNoticeRows.width(notice) == TextDraw.width("Reading › Starting agents · 7s", font: font))
        #expect(HomeNoticeRows.line(notice) == "Reading › Starting agents · 7s")
    }

    /// A narrow column cuts the folded steps first: the step now and its time stay whole.
    @Test func aNarrowColumnCutsTheStepsNotTheStepNow() throws {
        let font = HomeFonts.system(ofSize: 11)
        let notice = "Ran 3 commands · Read 2 files ›\nWaiting for a31's tests\nStarting agents · 7s"
        let wide = HomeNoticeRows.fittedParts(notice, font: font, maxWidth: 1000)
        #expect(wide.lead == "Ran 3 commands · Read 2 files › Waiting for a31's tests")
        #expect(wide.last == "Starting agents · 7s")
        let now = TextDraw.width("Starting agents · 7s", font: font)
        let room = now + TextDraw.width(HomeNoticeRows.separator, font: font) + TextDraw.width("Ran 3 commands…", font: font) + 1
        let narrow = HomeNoticeRows.fittedParts(notice, font: font, maxWidth: room)
        #expect(narrow.lead == "Ran 3 commands…")
        #expect(narrow.last == "Starting agents · 7s")
        let tight = HomeNoticeRows.fittedParts(notice, font: font, maxWidth: now - 20)
        #expect(tight.lead == nil)
        #expect(tight.last.hasSuffix("…"))
    }

    /// User 2026-10-29: the status line over the iMessage typing bubble cut its steps mid-word ("Ran 3 co…").
    /// The folded steps give way whole parts at a time: a stub is dropped, never drawn.
    @Test(arguments: [CGFloat(0), 6, 20, 40, 60, 90, 140, 200, 260])
    func theStepsNeverCutMidWord(extra: CGFloat) {
        let font = HomeFonts.system(ofSize: 11)
        let notice = "Ran 3 commands · Read 2 files ›\nWaiting for a31's tests\nChecking on a31 · 2m 10s"
        let now = TextDraw.width("Checking on a31 · 2m 10s", font: font)
        let fit = HomeNoticeRows.fittedParts(notice, font: font, maxWidth: now + extra)
        #expect(fit.last == "Checking on a31 · 2m 10s")
        let allowed: Set<String?> = [nil, "Ran 3 commands…", "Ran 3 commands · Read 2 files ›",
                                     "Ran 3 commands · Read 2 files › Waiting for a31's tests"]
        #expect(allowed.contains(fit.lead), "lead: \(fit.lead ?? "nil")")
        let drawn = fit.lead.map { HomeNoticeRows.joined([$0, fit.last]) } ?? fit.last
        #expect(TextDraw.width(drawn, font: font) <= now + extra + 0.5)
    }

    /// A cut right after the folded steps keeps their "›" whole, with no "…" or dot after it:
    /// "Ran 3 commands · Read 2 files › Checking on a31 · 2m 10s".
    @Test func aCutAfterTheFoldKeepsItsChevron() {
        let font = HomeFonts.system(ofSize: 11)
        let notice = "Ran 3 commands · Read 2 files ›\nWaiting for a31's tests\nChecking on a31 · 2m 10s"
        let line = "Ran 3 commands · Read 2 files › Checking on a31 · 2m 10s"
        let fit = HomeNoticeRows.fittedParts(notice, font: font, maxWidth: TextDraw.width(line, font: font) + 2)
        #expect(fit.lead == "Ran 3 commands · Read 2 files ›")
    }

    @Test func aNewThoughtShowsWithoutWaitingForTheClock() {
        let now = Self.t0
        let line = HomeLiveLine(now: { now })
        var shown: [String?] = []
        line.dispatch = { shown.append($0) }
        let activity = HomeLiveActivity(line: "Checking on a31", since: Self.t0)
        line.show(activity)
        line.show(activity, thought: "Waiting for the tests")
        #expect(shown.last == "Waiting for the tests\nChecking on a31")
        line.stop()
    }
}

/// The store keeps the run's newest thought for the indicator, also after the thought's step ended.
@MainActor @Suite(.serialized) struct HomeTurnThoughtStoreTests {
    @Test func theNewestThoughtOutlivesItsStepAndReachesTheStatusLine() async throws {
        let rig = try await HomeChatRig(history: 2)
        defer { rig.stop() }
        let conversation = HomeChatRig.conversation
        rig.store.handle(.live(.activity(HomeLiveActivityFrame(conversation: conversation, author: rig.chief, run: "r1",
                                                               activity: HomeLiveActivity(line: "Checking on a31", since: Date())))))
        rig.store.handle(.live(.delta(HomeLiveDelta(conversation: conversation, author: rig.chief, run: "r1", step: "thought:0",
                                                    isTalk: false, seq: 0, text: "**Waiting for a31**", isFinal: false))))
        // The store publishes the thought's headline, not its whole text.
        #expect(rig.store.liveRun(in: conversation)?.thought == "Waiting for a31")
        // Its last frame ends the step; the thought stays the run's narration until the next one.
        rig.store.handle(.live(.delta(HomeLiveDelta(conversation: conversation, author: rig.chief, run: "r1", step: "thought:0",
                                                    isTalk: false, seq: 1, text: "\n\n**Reading its test log**", isFinal: true))))
        #expect(rig.store.liveRun(in: conversation)?.thought == "Reading its test log")
        rig.frame()
        #expect(rig.view.debugStatusLine?.components(separatedBy: "\n").first == "Reading its test log")
    }
}
