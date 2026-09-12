import Foundation
import JavaScriptCore
import Testing
@testable import CmuxBrowser

@Suite("Video background embed playback")
@MainActor
struct VideoBackgroundEmbedPlaybackTests {
    @Test func managedPlaylistFinishesOnlyAfterItsLastVideo() throws {
        let context = try makePlayer(source: .youTubePlaylist(id: "PLtest"), queueManaged: true)
        try evaluate("emitState(0)", in: context)
        #expect(context.evaluateScript("hostEvents.length")?.toInt32() == 0)
        try evaluate("playlistIndex = 1; emitState(0)", in: context)
        #expect(context.evaluateScript("hostEvents.length")?.toInt32() == 0)
        try evaluate("playlistIndex = 2; emitState(0)", in: context)
        #expect(context.evaluateScript("hostEvents.map(payload => payload.event).join(',')")?.toString() == "ended")
    }

    @Test func managedPlaylistWithoutMetadataDoesNotPrematurelyAdvanceTheQueue() throws {
        let context = try makePlayer(source: .youTubePlaylist(id: "PLtest"), queueManaged: true)
        try evaluate("playlist = null; playlistIndex = -1; emitState(0)", in: context)
        #expect(context.evaluateScript("hostEvents.length")?.toInt32() == 0)
    }

    @Test func managedVideoFinishesButPausedPlaybackDoesNotAdvance() throws {
        let context = try makePlayer(source: .youTubeVideo(id: "abcdefghijk"), queueManaged: true)
        try evaluate("window.cmuxVideoBackgroundSetPaused(true); emitState(0)", in: context)
        #expect(context.evaluateScript("hostEvents.length")?.toInt32() == 0)
        try evaluate("window.cmuxVideoBackgroundSetPaused(false); emitState(0)", in: context)
        #expect(context.evaluateScript("hostEvents.map(payload => payload.event).join(',')")?.toString() == "ended")
    }

    @Test func loopingPlaylistWrapsPastItsLastErrorWithABoundedRetryBudget() throws {
        let context = try makePlayer(source: .youTubePlaylist(id: "PLtest"))
        try evaluate("playlistIndex = 2; emitError()", in: context)
        #expect(context.evaluateScript("playlistIndex")?.toInt32() == 0)
        #expect(context.evaluateScript("nextCalls")?.toInt32() == 1)
        try evaluate("emitError(); emitError()", in: context)
        #expect(context.evaluateScript("nextCalls")?.toInt32() == 2)
        #expect(context.evaluateScript("hostEvents.map(payload => payload.event).join(',')")?.toString() == "skipped,skipped,error")
    }

    @Test func successfulPlaybackResetsThePlaylistErrorBudget() throws {
        let context = try makePlayer(source: .youTubePlaylist(id: "PLtest"))
        try evaluate("playlistIndex = 2; emitError(); emitError(); emitState(1); emitError()", in: context)
        #expect(context.evaluateScript("nextCalls")?.toInt32() == 3)
        #expect(context.evaluateScript("hostEvents.some(payload => payload.event === 'error')")?.toBool() == false)
    }

    @Test func managedPlaylistDoesNotWrapOnItsLastError() throws {
        let context = try makePlayer(source: .youTubePlaylist(id: "PLtest"), queueManaged: true)
        try evaluate("playlistIndex = 2; emitError()", in: context)
        #expect(context.evaluateScript("nextCalls")?.toInt32() == 0)
        #expect(context.evaluateScript("hostEvents.map(payload => payload.event).join(',')")?.toString() == "error")
    }

    @Test func oneItemAndMetadataFreePlaylistsCannotRetryForever() throws {
        let context = try makePlayer(source: .youTubePlaylist(id: "PLtest"))
        try evaluate("playlist = ['only']; emitError()", in: context)
        #expect(context.evaluateScript("nextCalls")?.toInt32() == 0)
        #expect(context.evaluateScript("hostEvents[0].event")?.toString() == "error")
        try evaluate("playlist = null; playlistIndex = -1; hostEvents = []; for (let attempt = 0; attempt < 17; attempt++) emitError()", in: context)
        #expect(context.evaluateScript("nextCalls")?.toInt32() == 16)
        #expect(context.evaluateScript("hostEvents[16].event")?.toString() == "error")
    }

    @Test(arguments: [false, true])
    func loopingVideoWrapsThePlayheadBeforeAndAfterReadiness(readyFirst: Bool) throws {
        let context = try makePlayer(source: .youTubeVideo(id: "abcdefghijk"), ready: readyFirst)
        try evaluate("window.cmuxVideoBackgroundSetPosition(250)", in: context)
        if !readyFirst { try evaluate("emitReady()", in: context) }
        #expect(context.evaluateScript("seeks[seeks.length - 1]")?.toDouble() == 10)
        try evaluate("window.cmuxVideoBackgroundSetPosition(240)", in: context)
        #expect(context.evaluateScript("seeks[seeks.length - 1]")?.toDouble() == 0)
        try evaluate("window.cmuxVideoBackgroundSetPosition(0)", in: context)
        #expect(context.evaluateScript("seeks[seeks.length - 1]")?.toDouble() == 0)
    }

    @Test func seekWaitsForDurationAndDoesNotReplayOnEveryPlayingEvent() throws {
        let context = try makePlayer(source: .youTubeVideo(id: "abcdefghijk"), ready: false)
        try evaluate("duration = 0; window.cmuxVideoBackgroundSetPosition(250); emitReady()", in: context)
        #expect(context.evaluateScript("seeks.length")?.toInt32() == 0)
        try evaluate("duration = 120; emitState(1); emitState(1)", in: context)
        #expect(context.evaluateScript("seeks.length")?.toInt32() == 1)
        #expect(context.evaluateScript("seeks[0]")?.toDouble() == 10)
    }

    @Test func queueManagedVideoClampsRatherThanLoopsThePlayhead() throws {
        let context = try makePlayer(source: .youTubeVideo(id: "abcdefghijk"), queueManaged: true)
        try evaluate("window.cmuxVideoBackgroundSetPosition(250)", in: context)
        #expect(context.evaluateScript("seeks[0]")?.toDouble() == 120)
    }

    @Test(arguments: [false, true])
    func playlistDoesNotInterpretAggregateElapsedTimeAsAVideoTimestamp(queueManaged: Bool) throws {
        let context = try makePlayer(source: .youTubePlaylist(id: "PLtest"), queueManaged: queueManaged)
        try evaluate("window.cmuxVideoBackgroundSetPosition(250); emitReady()", in: context)
        try evaluate("playlistIndex = 1; duration = 90; window.cmuxVideoBackgroundSetPosition(500); emitState(1)", in: context)
        #expect(context.evaluateScript("seeks.length")?.toInt32() == 0)
        #expect(context.evaluateScript("playlistIndex")?.toInt32() == 1)
        #expect(context.evaluateScript("hostEvents.length")?.toInt32() == 0)
    }

    private func evaluate(_ script: String, in context: JSContext) throws {
        context.evaluateScript(script)
        try #require(context.exception == nil, "JavaScript error: \(context.exception?.toString() ?? "")")
    }

    private func makePlayer(
        source: VideoBackgroundSource,
        queueManaged: Bool = false,
        ready: Bool = true
    ) throws -> JSContext {
        let context = try #require(JSContext())
        try evaluate("""
        var hostEvents = [], seeks = [], playlist = ['first', 'second', 'third'];
        var playlistIndex = 0, nextCalls = 0, duration = 120, callbacks, fakePlayer;
        var window = {
          innerWidth: 960, innerHeight: 540, addEventListener: function () {},
          webkit: { messageHandlers: { cmuxVideoBackground: { postMessage: function (payload) { hostEvents.push(payload); } } } }
        };
        var document = {
          getElementById: function () { return {style: {}}; },
          createElement: function () { return {}; },
          body: {appendChild: function () {}}
        };
        var YT = {
          PlayerState: {ENDED: 0, PLAYING: 1},
          Player: function (identifier, options) {
            callbacks = options.events;
            var looping = !!options.playerVars.loop;
            fakePlayer = {
              mute: function () {}, unMute: function () {}, setVolume: function () {},
              playVideo: function () {}, pauseVideo: function () {},
              getDuration: function () { return duration; },
              seekTo: function (position) { seeks.push(position); },
              getPlaylist: function () { return playlist; },
              getPlaylistIndex: function () { return playlistIndex; },
              setLoop: function (value) { looping = value; },
              nextVideo: function () {
                nextCalls++;
                if (playlist) playlistIndex = looping ? (playlistIndex + 1) % playlist.length : playlistIndex + 1;
              }
            };
            return fakePlayer;
          }
        };
        function emitReady() { callbacks.onReady({target: fakePlayer}); hostEvents = []; }
        function emitState(state) { callbacks.onStateChange({data: state, target: fakePlayer}); }
        function emitError() { callbacks.onError({data: 150, target: fakePlayer}); }
        """, in: context)
        let html = VideoBackgroundEmbedPage(source: source, queueManaged: queueManaged).html
        let scriptStart = try #require(html.range(of: "<script>"))
        let scriptEnd = try #require(html.range(of: "</script>", range: scriptStart.upperBound..<html.endIndex))
        try evaluate(String(html[scriptStart.upperBound..<scriptEnd.lowerBound]), in: context)
        try evaluate("onYouTubeIframeAPIReady()", in: context)
        if ready { try evaluate("emitReady()", in: context) }
        return context
    }
}
