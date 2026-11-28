import CmuxAgentChat
import Foundation
import Testing
@testable import CmuxMobileHost

@Suite("Agent chat hook turn")
struct AgentChatHookTurnTests {
    private let since = Date(timeIntervalSince1970: 100)

    @Test("Only a prompt opens a turn and only a Stop settles one")
    func boundaries() {
        for turn in [AgentChatHookTurn.unknown, .open, .settled] {
            #expect(turn.after(.promptSubmitted) == .open)
            #expect(turn.after(.stopped) == .settled)
            for hook in [AgentChatHookTurn.Hook.toolStarting, .toolFinished, .other] {
                #expect(turn.after(hook) == turn)
            }
        }
    }

    @Test("The stored boundary applies only when none was seen live")
    func storedBoundary() {
        #expect(AgentChatHookTurn.unknown.adoptingStored(settled: true) == .settled)
        #expect(AgentChatHookTurn.unknown.adoptingStored(settled: false) == .unknown)
        #expect(AgentChatHookTurn.open.adoptingStored(settled: true) == .open)
        #expect(AgentChatHookTurn.settled.adoptingStored(settled: false) == .settled)
    }

    @Test("A starting tool leaves a settled session as it is")
    func toolStartingWhileSettled() {
        for state in [ChatAgentState.idle, .working(since: since), .needsInput(since: since), .ended] {
            #expect(AgentChatHookTurn.settled.stateOverride(previous: state, hook: .toolStarting) == state)
        }
    }

    @Test("A tool result returns a settled session to idle")
    func toolFinishedWhileSettled() {
        for state in [ChatAgentState.idle, .working(since: since), .needsInput(since: since)] {
            #expect(AgentChatHookTurn.settled.stateOverride(previous: state, hook: .toolFinished) == .idle)
        }
        #expect(AgentChatHookTurn.settled.stateOverride(previous: .ended, hook: .toolFinished) == .ended)
    }

    @Test("Nothing is overridden outside a settled turn or for other hooks")
    func noOverride() {
        for turn in [AgentChatHookTurn.unknown, .open] {
            for hook in [AgentChatHookTurn.Hook.toolStarting, .toolFinished] {
                #expect(turn.stateOverride(previous: .idle, hook: hook) == nil)
            }
        }
        for hook in [AgentChatHookTurn.Hook.promptSubmitted, .stopped, .other] {
            #expect(AgentChatHookTurn.settled.stateOverride(previous: .idle, hook: hook) == nil)
        }
    }
}
