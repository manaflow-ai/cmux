import Testing
@testable import CmuxMobileModel

/// The remove-Mac confirmation: the "stays off" copy only for a Mac whose host said
/// `removal-v1`; an older Mac, or one never linked (unknown), keeps the truthful old copy.
@Suite struct MacRemovalCopyTests {
    @Test func onlyAMacThatSaidRemovalV1StaysOff() {
        #expect(MacRemovalCopy.honorsRemoval([["removal-v1"]]))
        #expect(MacRemovalCopy.honorsRemoval([nil, ["removal-v1", "other"]]))
        #expect(!MacRemovalCopy.honorsRemoval([[]]))
        #expect(!MacRemovalCopy.honorsRemoval([nil]))
        #expect(!MacRemovalCopy.honorsRemoval([]))
    }

    @Test func theCopyMatchesWhatTheMacDoes() {
        #expect(MacRemovalCopy.online(honorsRemoval: true)
            == "Disconnects now. Reconnect with Allow Again in the Mac’s Settings → Mobile.")
        #expect(MacRemovalCopy.online(honorsRemoval: false).contains("May return automatically"))
    }

    @Test func waitingPhrasesNameWhatTheAgentAsks() {
        var tab = WorkspaceTab(id: "s7", kind: .agent, title: "Refactor", harness: "claude", agentStatus: .waiting, waitingFor: .permission)
        #expect(tab.waitingPhrase == "Claude is asking permission")
        tab.waitingFor = .question
        #expect(tab.waitingPhrase == "Claude has a question")
        tab.waitingFor = nil
        #expect(tab.waitingPhrase == "Claude is waiting")
    }
}
