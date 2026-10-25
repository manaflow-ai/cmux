import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Memory Saver keep rules, live: real WebKit pages through the app's hibernation under critical
/// memory pressure, each reason compared by its `debug.surfaces` name. Lawrence 2026-10-24 (CLAUDE.md
/// "Copy Chrome's performance model"): a hidden page with audio, capture, the person's form input, a
/// running download or a `beforeunload` that asks is never discarded, at any memory pressure.
///
/// Before: a running Web Audio context kept a page only until critical pressure, and a page whose
/// `beforeunload` asks ("Leave site? Changes you made may not be saved") or that holds a live WebRTC
/// call was discarded like any other.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct MemorySaverKeepRulesLiveTests {
    // MARK: beforeunload, live (real WebKit pages, critical memory pressure)

    /// The person used the page and its `beforeunload` asks: Chrome and Safari would ask before a close.
    @Test func aUsedPageWhoseBeforeUnloadAsksIsNeverDiscarded() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await rig.page("asks", body: Self.usedPage(handler: "e.preventDefault(); e.returnValue = '';"))
        try await rig.pressDown(page)
        rig.window.contentView = nil
        let key = try await rig.hide(page)
        try await rig.until("the page hibernated or was kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key)?.rawValue == "before_unload", "a page whose beforeunload asks was not kept for it")
        #expect(!rig.isHibernated(key), "a page whose beforeunload asks was discarded")
    }

    /// The legacy form: `onbeforeunload` returns a message.
    @Test func aUsedPageWhoseOnBeforeUnloadReturnsAMessageIsNeverDiscarded() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await rig.page("legacy", body: """
            <div style="height: 2000px"></div>
            <script>
            addEventListener('keydown', (e) => { window.pressed = e.isTrusted; }, true);
            window.onbeforeunload = () => 'Unsaved changes';
            </script>
            """)
        try await rig.pressDown(page)
        rig.window.contentView = nil
        let key = try await rig.hide(page)
        try await rig.until("the page hibernated or was kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key)?.rawValue == "before_unload")
        #expect(!rig.isHibernated(key))
    }

    /// A page nobody used cannot ask (Chromium and WebKit show no beforeunload question without the
    /// person's activation): it hibernates, as Chrome would close it without asking.
    @Test func anUnusedPageWithABeforeUnloadHandlerHibernates() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let key = try await rig.hide(rig.page("unused", body: Self.usedPage(handler: "e.preventDefault(); e.returnValue = '';")))
        try await rig.until("the page hibernated or was kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key) == nil)
        #expect(rig.isHibernated(key))
    }

    /// An editor that asks only while it holds unsaved changes (Google Docs, GitHub) has none: it hibernates.
    @Test func aUsedPageWhoseBeforeUnloadDoesNotAskHibernates() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await rig.page("saved", body: Self.usedPage(handler: "if (window.dirty) e.preventDefault();"))
        try await rig.pressDown(page)
        rig.window.contentView = nil
        let key = try await rig.hide(page)
        try await rig.until("the page hibernated or was kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key) == nil, "a page whose beforeunload would not ask was kept")
        #expect(rig.isHibernated(key))
    }

    /// A child frame the person used, with its own beforeunload handler, keeps the tab.
    @Test func aUsedChildFrameWithABeforeUnloadHandlerKeepsThePage() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let child = """
            <input id='f' value='x'><script>
            addEventListener('keydown', (e) => { parent.pressed = e.isTrusted; }, true);
            addEventListener('beforeunload', (e) => { e.preventDefault(); });
            </script>
            """
        let page = try await rig.page("child", body: """
            <iframe id="child" srcdoc="\(child.replacingOccurrences(of: "\"", with: "&quot;"))"></iframe>
            """)
        try await rig.until("the child frame loads") {
            (try? await page.evaluate("!!document.getElementById('child').contentDocument?.getElementById('f')", world: .page, gesture: .agent)) == .bool(true)
        }
        rig.window.contentView = page.contentView
        rig.window.makeFirstResponder(page.webView)
        _ = try await page.evaluate("document.getElementById('child').contentDocument.getElementById('f').focus(); true", world: .page, gesture: .agent)
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: rig.window.windowNumber, context: nil,
                                                 characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        page.webView.keyDown(with: down)
        try await rig.until("the key reached the child frame") {
            (try? await page.evaluate("window.pressed === true", world: .page, gesture: .agent)) == .bool(true)
        }
        rig.window.contentView = nil
        let key = try await rig.hide(page)
        try await rig.until("the page hibernated or was kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key)?.rawValue == "before_unload", "a used child frame's beforeunload did not keep the page")
        #expect(!rig.isHibernated(key))
    }

    /// The probe ran the page's own beforeunload handlers, as a synthetic close, on a page that
    /// stays: on every replan (each tab switch, every 3 s at critical pressure), and inside cmux's
    /// user gesture. A handler that closes a socket, stops reconnects or sends a "left" beacon then
    /// left the person a dead page. A page something else keeps (here running Web Audio) must never
    /// have its handlers run.
    @Test func aPageKeptForAnotherReasonNeverRunsItsBeforeUnload() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await rig.page("synth-unload", body: """
            <div style="height: 2000px"></div>
            <script>
            window.unloadRuns = 0;
            addEventListener('keydown', (e) => { window.pressed = e.isTrusted; window.synth = new AudioContext(); window.synth.resume(); }, true);
            addEventListener('beforeunload', (e) => { window.unloadRuns += 1; e.preventDefault(); e.returnValue = ''; });
            </script>
            """)
        try await rig.pressDown(page)
        try await rig.until("the audio context runs") {
            (try? await page.evaluate("window.synth?.state === 'running'", world: .page, gesture: .cmux)) == .bool(true)
        }
        rig.window.contentView = nil
        let key = try await rig.hide(page)
        try await rig.until("the page was kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key)?.rawValue == "web_audio")
        try await Self.replan(rig, key, times: 2)
        // A frozen page runs no script: as an agent's call, this thaws it.
        rig.hibernation.noteAgentUse(key)
        #expect(try await page.evaluate("window.unloadRuns", world: .page, gesture: .cmux) == .number(0),
                "the probe ran the beforeunload handlers of a page Web Audio keeps")
    }

    /// A page whose beforeunload asks is asked once while it stays hidden (each run is its own
    /// unload logic on a page that lives on), and without a user gesture: a handler cannot open a
    /// popup or see an activation on cmux's behalf.
    @Test func aPageWhoseBeforeUnloadAsksIsAskedOnceWithoutAGesture() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await rig.page("asks-once", body: """
            <div style="height: 2000px"></div>
            <script>
            window.unloadGestures = [];
            addEventListener('keydown', (e) => { window.pressed = e.isTrusted; }, true);
            addEventListener('beforeunload', (e) => {
              window.unloadGestures.push(navigator.userActivation?.isActive === true);
              e.preventDefault(); e.returnValue = '';
            });
            </script>
            """)
        try await rig.pressDown(page)
        rig.window.contentView = nil
        let key = try await rig.hide(page)
        try await rig.until("the page was kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key)?.rawValue == "before_unload")
        try await Self.replan(rig, key, times: 3)
        #expect(rig.exemption(key)?.rawValue == "before_unload", "a page that asked was discarded on a later replan")
        #expect(!rig.isHibernated(key))
        rig.hibernation.noteAgentUse(key)
        #expect(try await page.evaluate("JSON.stringify(window.unloadGestures)", world: .page, gesture: .cmux) == .string("[false]"),
                "the handlers ran more than once, or inside a user gesture")
    }

    /// Runs `times` discard probes of hidden page `key`, one after another.
    private static func replan(_ rig: HiddenPageHibernationTests.Rig, _ key: String, times: Int) async throws {
        for _ in 0..<times {
            try await rig.until("the last probe ended") { !rig.hibernation.probing.contains(key) }
            rig.hibernation.replan()
            #expect(rig.hibernation.probing.contains(key), "the replan did not probe the kept page")
            try await rig.until("the probe ended") { !rig.hibernation.probing.contains(key) }
        }
    }

    // MARK: Web Audio, live

    /// A running AudioContext (a game, a synth, a call's ringtone engine) at critical pressure.
    @Test func aPageWithARunningAudioContextIsKeptUnderCriticalPressure() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await rig.page("synth", body: """
            <div style="height: 2000px"></div>
            <script>
            addEventListener('keydown', (e) => {
              window.pressed = e.isTrusted;
              window.synth = new AudioContext();
              window.synth.resume();
            }, true);
            </script>
            """)
        try await rig.pressDown(page)
        try await rig.until("the audio context runs") {
            (try? await page.evaluate("window.synth?.state === 'running'", world: .page, gesture: .agent)) == .bool(true)
        }
        rig.window.contentView = nil
        let key = try await rig.hide(page)
        try await rig.until("the page hibernated or was kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key)?.rawValue == "web_audio", "a page with running Web Audio was not kept for it")
        #expect(!rig.isHibernated(key), "a page with running Web Audio was discarded under critical pressure")
    }

    // MARK: WebRTC, live

    /// A connected RTCPeerConnection (a call that only listens, a data channel) keeps the page: a
    /// discard would end the call.
    @Test func aPageWithAConnectedPeerConnectionIsNeverDiscarded() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await rig.page("call", body: """
            <script>
            (async () => {
              const a = new RTCPeerConnection(), b = new RTCPeerConnection();
              a.onicecandidate = (e) => e.candidate && b.addIceCandidate(e.candidate);
              b.onicecandidate = (e) => e.candidate && a.addIceCandidate(e.candidate);
              a.createDataChannel('call');
              await a.setLocalDescription(await a.createOffer());
              await b.setRemoteDescription(a.localDescription);
              await b.setLocalDescription(await b.createAnswer());
              await a.setRemoteDescription(b.localDescription);
              window.peers = [a, b];
            })();
            </script>
            """)
        try await rig.until("the peers connect") {
            (try? await page.evaluate("!!window.peers && window.peers.every((p) => p.connectionState === 'connected')", world: .page, gesture: .agent)) == .bool(true)
        }
        let key = try await rig.hide(page)
        try await rig.until("the page hibernated or was kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key)?.rawValue == "web_rtc", "a page with a live peer connection was not kept for it")
        #expect(!rig.isHibernated(key))
    }

    /// A page with a `beforeunload` handler `handler` (body of `(e) => { ... }`) that notes the person's key.
    private static func usedPage(handler: String) -> String {
        """
        <div style="height: 2000px"></div>
        <script>
        addEventListener('keydown', (e) => { window.pressed = e.isTrusted; }, true);
        addEventListener('beforeunload', (e) => { \(handler) });
        </script>
        """
    }
}
