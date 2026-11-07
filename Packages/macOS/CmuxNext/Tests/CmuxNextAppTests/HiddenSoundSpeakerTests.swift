import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Issue 38062: a tab playing sound showed no speaker, on the tab or its sidebar row, when the
/// sound came from outside the document: the media observer looks only for `<video>` and `<audio>`
/// in it, so a detached `new Audio()` (web radios, stream players), an element in a shadow root and
/// Web Audio went unseen, and Mute had nothing to show. Real WebKit pages, each started by the
/// person's key press; the speaker is `BrowserTabAudio.badge`, what the strip and the sidebar row draw.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct HiddenSoundSpeakerTests {
    @Test func aDetachedAudioElementShowsTheSpeakerUntilItStops() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await rig.page("detached", body: Self.onKey("window.a = new Audio(\(Self.tone)); a.loop = true; a.play();"))
        try await rig.pressDown(page)
        try await Self.until(rig, page, "the detached audio plays", "!!window.a && !a.paused && a.currentTime > 0")
        try await rig.until("the tab shows its speaker") { BrowserTabAudio.badge(page.state) == .playing }
        _ = try await page.evaluate("a.pause(); true", world: .page, gesture: .cmux)
        try await rig.until("the speaker clears once the audio stops") { BrowserTabAudio.badge(page.state) == nil }
    }

    @Test func anAudioElementInAClosedShadowRootShowsTheSpeaker() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await rig.page("shadow", body: """
            <div id="host"></div>
            <script>
            const root = document.getElementById('host').attachShadow({ mode: 'closed' });
            const player = document.createElement('audio');
            player.src = \(Self.tone);
            player.loop = true;
            root.appendChild(player);
            window.playing = () => !player.paused && player.currentTime > 0;
            window.stop = () => player.pause();
            </script>
            \(Self.onKey("player.play();"))
            """)
        try await rig.pressDown(page)
        try await Self.until(rig, page, "the shadow root's audio plays", "window.playing()")
        try await rig.until("the tab shows its speaker") { BrowserTabAudio.badge(page.state) == .playing }
        _ = try await page.evaluate("stop(); true", world: .page, gesture: .cmux)
        try await rig.until("the speaker clears once the audio stops") { BrowserTabAudio.badge(page.state) == nil }
    }

    @Test func webAudioShowsTheSpeakerButNoMediaSession() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await rig.page("synth", body: Self.onKey("""
            window.synth = new AudioContext();
            window.tone = synth.createOscillator();
            const gain = synth.createGain();
            gain.gain.value = 0.01;
            tone.connect(gain).connect(synth.destination);
            tone.start();
            synth.resume();
            """))
        try await rig.pressDown(page)
        try await Self.until(rig, page, "the audio context runs", "window.synth?.state === 'running'")
        try await rig.until("the tab shows its speaker") { BrowserTabAudio.badge(page.state) == .playing }
        let key = page.id.rawValue
        rig.keys.append(key)
        rig.services.cache.install(page, for: key)
        let cache = rig.services.cache
        #expect(cache.pageRequests.media.sessions(in: cache).isEmpty, "Web Audio has nothing the media hub could pause")
        _ = try await page.evaluate("tone.stop(); true", world: .page, gesture: .cmux)
        try await rig.until("the speaker clears once the sound stops") { BrowserTabAudio.badge(page.state) == nil }
    }

    /// A page script that notes the person's key (`window.pressed`, what `Rig.pressDown` waits for) and runs `start`.
    private static func onKey(_ start: String) -> String {
        "<script>addEventListener('keydown', (e) => { window.pressed = e.isTrusted; \(start) }, true);</script>"
    }

    private static func until(_ rig: HiddenPageHibernationTests.Rig, _ page: WebKitTab, _ what: String, _ check: String) async throws {
        try await rig.until(what) { (try? await page.evaluate(check, world: .page, gesture: .cmux)) == .bool(true) }
    }

    /// A blob URL of one second of a quiet 440 Hz tone, 16-bit mono WAV (a JS expression).
    private static let tone = """
        (() => { const rate = 22050, n = rate, b = new ArrayBuffer(44 + n * 2), v = new DataView(b);
          const w = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
          w(0, 'RIFF'); v.setUint32(4, 36 + n * 2, true); w(8, 'WAVEfmt '); v.setUint32(16, 16, true);
          v.setUint16(20, 1, true); v.setUint16(22, 1, true); v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true);
          v.setUint16(32, 2, true); v.setUint16(34, 16, true); w(36, 'data'); v.setUint32(40, n * 2, true);
          for (let i = 0; i < n; i++) v.setInt16(44 + i * 2, 1000 * Math.sin(2 * Math.PI * 440 * i / rate), true);
          return URL.createObjectURL(new Blob([b], { type: 'audio/wav' })); })()
        """
}
