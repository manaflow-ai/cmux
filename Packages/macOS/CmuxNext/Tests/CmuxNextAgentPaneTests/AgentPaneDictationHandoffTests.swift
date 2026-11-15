import CmuxNextDictation
import CmuxNextSettings
import CmuxNextTestSupport
import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The mic's hand-off to the dictation app `agentPane.dictationSource` names
/// (``AgentPaneDictationHandoff``): it posts that app's chord, never one the page names, and only
/// for an app this Mac has, with Accessibility granted.
@MainActor struct AgentPaneDictationHandoffTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private final class Posted { var presses: [(CGKeyCode, CGEventFlags)] = []; var system = 0; var stops = 0 }

    private func handoff(installed: Set<String> = ["com.openai.codex"], mayPost: Bool = true, posted: Posted) -> AgentPaneDictationHandoff {
        var handoff = AgentPaneDictationHandoff()
        handoff.installedURL = { installed.contains($0) ? URL(fileURLWithPath: "/Applications/\($0).app") : nil }
        handoff.mayPost = { mayPost }
        handoff.post = { posted.presses.append(($0, $1)); return true }
        handoff.systemDictation = { posted.system += 1 }
        handoff.stopOwnDictation = { posted.stops += 1 }
        return handoff
    }

    private func setting(_ source: AgentPaneDictationSource, shortcut: String = "") -> AgentPaneComposerSetting {
        var setting = AgentPaneComposerSetting()
        setting.dictationSource = source
        setting.dictationShortcut = shortcut
        return setting
    }

    @Test func cmuxKeepsItsOwnDictation() {
        let posted = Posted()
        #expect(handoff(posted: posted).handOff(setting(.cmux)) == .ownDictation)
        #expect(posted.presses.isEmpty && posted.system == 0)
    }

    @Test func chatGPTGetsOptionSpace() {
        let posted = Posted()
        #expect(handoff(posted: posted).handOff(setting(.chatgpt)) == nil)
        #expect(posted.presses.count == 1)
        #expect(posted.presses.first?.0 == 49)  // kVK_Space
        #expect(posted.presses.first?.1 == .maskAlternate)
    }

    @Test func thePersonsChordWins() {
        let posted = Posted()
        #expect(handoff(posted: posted).handOff(setting(.chatgpt, shortcut: "ctrl+opt+d")) == nil)
        #expect(posted.presses.first?.0 == 2)  // kVK_ANSI_D
        #expect(posted.presses.first?.1 == [.maskControl, .maskAlternate])
    }

    @Test func macOSStartsSystemDictation() {
        let posted = Posted()
        #expect(handoff(installed: [], posted: posted).handOff(setting(.macos)) == nil)
        #expect(posted.system == 1 && posted.presses.isEmpty)
    }

    @Test func anAppThisMacLacksIsRefused() {
        let posted = Posted()
        #expect(handoff(posted: posted).handOff(setting(.wisprFlow)) == .notInstalled)
        #expect(posted.presses.isEmpty)
    }

    @Test func withoutAccessibilityNothingIsPosted() {
        let posted = Posted()
        #expect(handoff(mayPost: false, posted: posted).handOff(setting(.chatgpt)) == .noAccessibility)
        #expect(posted.presses.isEmpty)
    }

    @Test func sourcesListOnlyInstalledApps() {
        let posted = Posted()
        let sources = handoff(installed: ["com.openai.chat", "com.electron.wispr-flow"], posted: posted).sources()
        #expect(sources.map { $0["id"] as? String } == ["chatgpt", "wisprFlow"])
        #expect(sources.first?["bundleId"] as? String == "com.openai.chat")
    }

    @Test func everyDefaultChordParsesToAKey() {
        for app in AgentPaneDictationHandoff.apps {
            let chord = AgentPaneDictationShortcut(app.shortcut)
            #expect(chord != nil)
            #expect(chord.flatMap { AgentPaneDictationHandoff.keyCode($0.key) } != nil)
        }
    }

    @Test func thePageCallsItWithNoKeys() {
        #expect(AgentPaneRequest(body: ["method": "dictation.handoff", "params": ["keys": "cmd+q"]]) == .dictationHandoff)
        #expect(AgentPaneRequest(body: ["method": "dictation.sources"]) == .dictationSources)
        #expect(AgentPageOps.methods["dictation.handoff"] == "dictation.handoff")
        #expect(AgentPageOps.methods["dictation.sources"] == "dictation.sources")
    }

    @Test(arguments: ["cmux", "macos", "chatgpt", "wisprFlow"])
    func eachSourceWritesTheKey(_ source: String) {
        let request = AgentPaneRequest(body: ["method": "pane.setDictationSource", "params": ["source": source]])
        #expect(request == .displaySetting(path: ["agentPane", "dictationSource"], value: .string(source)))
    }

    @Test func anyOtherSourceIsRefused() {
        for params: [String: Any] in [["source": "ChatGPT"], ["source": "siri"], ["source": true], [:]] {
            let request = AgentPaneRequest(body: ["method": "pane.setDictationSource", "params": params])
            #expect(request == .unsupported("pane.setDictationSource"))
        }
    }

    /// A dictation app's icon is drawn only once `dictation.sources` listed it (this Mac has it):
    /// a page can't learn from an icon ask whether an app is installed.
    @Test func onlyListedDictationAppsHaveAnIcon() throws {
        let suite = "dictation-icons-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let icons = AttachmentSourceIcons(defaults: defaults, ownBundleId: "com.cmuxterm.test")
        // Finder stands in for an installed app: refused until listed.
        #expect(icons.dataURL("com.apple.finder") == nil)
        icons.noteDictationApps(["com.apple.finder"])
        #expect(icons.dataURL("com.apple.finder")?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test func aShortcutFailureReachesThePage() {
        let event = AgentPageEvent.dictationHandoff(failure: AgentPaneDictationHandoff.code(.noAccessibility))
        #expect(event.kind == "dictationHandoff")
        #expect(event.value.value(at: ["code"])?.stringValue == "dictation.accessibility")
    }

    /// The hand-off posts keys into the app in front: page script, or a gesture only the page saw,
    /// gets nothing posted; the person's own click in the pane goes through, once.
    @Test func theHandoffNeedsAUserGesture() async {
        let posted = Posted()
        let model = AgentPaneModel(host: NoHost())
        model.dictationHandoff = handoff(posted: posted)
        model.composer = setting(.chatgpt)
        let refused = await model.respond(to: .dictationHandoff, userGesture: false)
        #expect(refused["ok"] as? Bool != true)
        // A page's gesture alone is not enough: it counts a click another process posted too.
        let pageOnly = await model.respond(to: .dictationHandoff, userGesture: true)
        #expect(pageOnly["ok"] as? Bool != true)
        #expect(posted.presses.isEmpty)
        // A key press the person typed elsewhere in the pane leaves a credit, but not a click: refused.
        model.transport.gestures.record()
        _ = await model.respond(to: .dictationHandoff, userGesture: true)
        #expect(posted.presses.isEmpty)
        // The person's own click in the pane (AgentPaneView's judge records it), spent once.
        model.transport.gestures.record(click: true)
        _ = await model.respond(to: .dictationHandoff, userGesture: true)
        #expect(posted.presses.count == 1)
        _ = await model.respond(to: .dictationHandoff, userGesture: true)
        #expect(posted.presses.count == 1)
    }

    /// A hand-off ends cmux's own dictation first (in any pane): one listener at a time.
    @Test func aHandoffEndsCmuxsOwnDictationFirst() {
        let posted = Posted()
        let handoff = handoff(posted: posted)
        #expect(handoff.handOff(setting(.chatgpt)) == nil)
        #expect(handoff.handOff(setting(.macos)) == nil)
        #expect(posted.stops == 2)
        // Nothing to hand off to: cmux's own session is left alone.
        #expect(handoff.handOff(setting(.cmux)) == .ownDictation)
        #expect(handoff.handOff(setting(.wisprFlow)) == .notInstalled)
        #expect(posted.stops == 2)
    }

    /// Home's or a terminal's dictation holds the microphone through the app's claims: the
    /// hand-off's yield stops it too, keeping its words, and leaves the microphone to no one.
    @Test func aYieldStopsWhoeverHoldsTheMicrophone() {
        let claims = DictationMicrophoneClaims()
        let home = NSObject()
        var stopped = 0
        claims.claim(home) { stopped += 1 }
        claims.yield()
        #expect(stopped == 1)
        #expect(!claims.isHeld(by: home))
        claims.yield()
        #expect(stopped == 1)
    }

    /// A chord the person set that does not parse is refused, never swapped for the app's default.
    @Test func aBadChordIsRefusedNotReplaced() {
        let posted = Posted()
        #expect(handoff(posted: posted).handOff(setting(.chatgpt, shortcut: "ctrl+")) == .badShortcut)
        #expect(posted.presses.isEmpty)
    }
}
