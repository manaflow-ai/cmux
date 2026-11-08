import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextDictation

/// The composer's outside-dictation mark (design/composer-dictation.md): the host watches the
/// microphone only while a composer has the keyboard, tells the page when another app takes or
/// releases it, and never opens it.
@MainActor struct MicrophoneActivityTests {
    private final class Owner {}

    @Test func listenersRunOnlyWhileSomeoneWatches() {
        let activity = MicrophoneActivity()
        activity.read = { _ in .idle }
        #expect(!activity.isListening)
        let first = Owner(), second = Owner()
        activity.watch(first) { _ in }
        activity.watch(second) { _ in }
        activity.unwatch(first)
        activity.unwatch(second)
        // The last watcher out removes every listener and forgets the state.
        #expect(!activity.isListening)
        #expect(activity.state == .idle)
    }

    @Test func watchersHearEachChangeOnce() {
        let activity = MicrophoneActivity()
        var next = MicrophoneActivity.State.idle
        activity.read = { _ in next }
        var heard: [MicrophoneActivity.State] = []
        let owner = Owner()
        activity.watch(owner) { heard.append($0) }
        next = MicrophoneActivity.State(active: true, bundleId: "com.openai.codex", name: "ChatGPT")
        activity.refresh()
        activity.refresh()
        next = .idle
        activity.refresh()
        #expect(heard.map(\.active) == [false, true, false])
        #expect(heard[1].name == "ChatGPT")
        activity.unwatch(owner)
    }

    @Test func nothingIsReadWithNoWatcher() {
        let activity = MicrophoneActivity()
        var reads = 0
        activity.read = { _ in reads += 1; return .idle }
        activity.refresh()
        #expect(reads == 0)
    }

    @Test func thePageEventCarriesTheApp() {
        let event = AgentPageEvent.micActivity(.init(active: true, bundleId: "com.electron.wispr-flow", name: "Wispr Flow"))
        #expect(event.kind == "micActivity")
        #expect(event.value.value(at: ["active"])?.boolValue == true)
        #expect(event.value.value(at: ["name"])?.stringValue == "Wispr Flow")
        #expect(AgentPageEvent.micActivity(.idle).value.value(at: ["bundleId"]) == nil)
    }

    @Test func thePageAsksToWatchWithABool() {
        #expect(AgentPaneRequest(body: ["method": "dictation.watchMicrophone", "params": ["on": true]]) == .watchMicrophone(true))
        #expect(AgentPaneRequest(body: ["method": "dictation.watchMicrophone", "params": ["on": "yes"]]) == .unsupported("dictation.watchMicrophone"))
        #expect(AgentPageOps.methods["dictation.watchMicrophone"] == "dictation.watchMicrophone")
    }
}
