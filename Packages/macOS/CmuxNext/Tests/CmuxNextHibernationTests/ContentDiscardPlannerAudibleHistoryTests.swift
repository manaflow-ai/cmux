import CmuxNextHibernation
import Observation
import Testing

/// ``AudibleHistory`` follows a source's audible bit as Chrome's page node does
/// (`PageNode::GetTimeSinceLastAudibleChange`): the end of a sound is recorded when the source says
/// so, with no poll, and its owner is told once, so the planner's next look is the minute's end.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ContentDiscardPlannerAudibleHistoryTests {
    @Observable final class Speaker {
        var playing = false
    }

    final class FakeNow {
        var now = ContinuousClock.now
    }

    @Test func theEndOfASoundIsRecordedAndReportedOnce() async {
        let clock = FakeNow()
        let history = AudibleHistory(now: { clock.now })
        let (ends, ended) = AsyncStream<String>.makeStream()
        history.onEnded = { ended.yield($0) }
        let speaker = Speaker()
        speaker.playing = true
        history.watch("song", speaker) { [weak speaker] in speaker?.playing == true }
        #expect(history.isWatchedAudible("song") == true)
        #expect(history.secondsSinceAudible("song") == 0)

        clock.now += .seconds(10)
        speaker.playing = false
        var iterator = ends.makeAsyncIterator()
        #expect(await iterator.next() == "song")
        #expect(history.isWatchedAudible("song") == false)

        clock.now += .seconds(30)
        #expect(history.secondsSinceAudible("song") == 30, "counted from the end of the sound, not its start")
        var candidate = ContentDiscardPlanner.Candidate(key: "song", hiddenFor: 3_600)
        candidate.secondsSinceAudible = history.secondsSinceAudible("song")
        #expect(DiscardRule.audioProtectionLeft(candidate) == 30)
    }

    @Test func aSourceThatNeverPlayedHasNoHistory() {
        let history = AudibleHistory()
        history.onEnded = { _ in Issue.record("a silent source has no end of sound") }
        let speaker = Speaker()
        history.watch("docs", speaker) { [weak speaker] in speaker?.playing == true }
        #expect(history.secondsSinceAudible("docs") == nil)
        #expect(history.isWatchedAudible("docs") == false)
    }

    @Test func aProbeHeardItAndForgetDropsIt() {
        let clock = FakeNow()
        let history = AudibleHistory(now: { clock.now })
        history.heard("song")
        clock.now += .seconds(61)
        var candidate = ContentDiscardPlanner.Candidate(key: "song", hiddenFor: 3_600)
        candidate.secondsSinceAudible = history.secondsSinceAudible("song")
        #expect(DiscardRule.audioProtectionLeft(candidate) == 0, "61 s after the sound the page is eligible")
        history.forget("song")
        #expect(history.secondsSinceAudible("song") == nil)
    }

    /// A source swapped under the same key (a restored page) is watched anew; the old one is ignored.
    @Test func aNewSourceUnderTheKeyIsWatchedAnew() async {
        let history = AudibleHistory()
        let (ends, ended) = AsyncStream<String>.makeStream()
        history.onEnded = { ended.yield($0) }
        let old = Speaker()
        old.playing = true
        history.watch("song", old) { [weak old] in old?.playing == true }
        history.unwatch("song")
        let restored = Speaker()
        restored.playing = true
        history.watch("song", restored) { [weak restored] in restored?.playing == true }
        old.playing = false
        restored.playing = false
        var iterator = ends.makeAsyncIterator()
        #expect(await iterator.next() == "song")
        #expect(history.isWatchedAudible("song") == false)
    }
}
