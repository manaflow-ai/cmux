import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Agent activity and resume safety")
struct AgentActivityClassifierTests {
    private func classify(_ configure: (inout AgentActivitySignals) -> Void) -> (AgentActivity, ResumeSafetyAssessment) {
        var signals = AgentActivitySignals()
        configure(&signals)
        let result = signals.classify()
        return (result.activity, result.safety)
    }

    @Test("an idle agent with no pending work is safe")
    func idle() {
        let (activity, safety) = classify { _ in }
        #expect(activity.kind == .idle)
        #expect(safety == ResumeSafetyAssessment(safety: .safe, reasons: [.idle]))
    }

    @Test("awaiting a human at the prompt is safe")
    func awaitingInput() {
        let (activity, safety) = classify { $0.awaitingInput = true }
        #expect(activity.kind == .awaitingInput)
        #expect(safety.safety == .safe)
    }

    @Test("a foreground Bash command is risky and carries its command")
    func foregroundTool() {
        let started = Date(timeIntervalSince1970: 100)
        let (activity, safety) = classify {
            $0.turnActive = true
            $0.openTool = .init(name: "Bash", command: "swift build", startedAt: started)
        }
        #expect(activity.kind == .tool)
        #expect(activity.tool?.command == "swift build")
        #expect(activity.since == started)
        #expect(safety.safety == .risky)
        #expect(safety.reasons == [.foregroundCommand])
    }

    @Test("read-only tools and model requests need care; between tool calls is safe")
    func careCases() {
        #expect(classify { $0.turnActive = true; $0.openTool = .init(name: "Grep") }.1.safety == .care)
        let thinking = classify { $0.turnActive = true }
        #expect(thinking.0.kind == .thinking)
        #expect(thinking.1 == ResumeSafetyAssessment(safety: .care, reasons: [.thinking]))
        let between = classify { $0.turnActive = true; $0.lastToolFinished = true }
        #expect(between.0.kind == .thinking)
        #expect(between.1 == ResumeSafetyAssessment(safety: .safe, reasons: [.betweenToolCalls]))
    }

    @Test("subagents and background work need care, not risky")
    func subagentsAndBackground() {
        let task = classify { $0.turnActive = true; $0.openTool = .init(name: "Task") }
        #expect(task.0.kind == .subagents)
        #expect(task.1.safety == .care)
        let background = classify { $0.backgroundWork = true }
        #expect(background.0.kind == .background)
        #expect(background.1 == ResumeSafetyAssessment(safety: .care, reasons: [.backgroundWork]))
    }

    @Test("an open question or permission is risky and outranks a running tool")
    func blockedOnHuman() {
        let permission = classify { $0.pendingPermission = true; $0.openTool = .init(name: "Bash", command: "rm -rf build") }
        #expect(permission.0.kind == .permission)
        #expect(permission.0.tool?.name == "Bash")
        #expect(permission.1.reasons == [.pendingPermission])
        #expect(classify { $0.pendingQuestion = true }.1.safety == .risky)
    }

    @Test("a live foreground child marks a command even when hooks say idle")
    func processTreeWinsOverStaleHooks() {
        let (activity, safety) = classify { $0.foregroundCommand = "ssh build-host make" }
        #expect(activity.kind == .tool)
        #expect(activity.source == .process)
        #expect(activity.tool?.command == "ssh build-host make")
        #expect(safety.safety == .risky)
    }

    @Test("a draft makes any live state risky, but not an ended one")
    func draft() {
        let idle = classify { $0.hasDraft = true }
        #expect(idle.1 == ResumeSafetyAssessment(safety: .risky, reasons: [.idle, .draft]))
        let ended = classify { $0.ended = true; $0.hasDraft = true }
        #expect(ended.1.safety == .safe)
    }

    @Test("no hook evidence is unknown, not idle")
    func unknown() {
        let (activity, safety) = classify { $0.hasHookEvidence = false }
        #expect(activity.kind == .unknown)
        #expect(safety.reasons == [.unknown])
    }

    @Test("wire names match the agents view and updater contract")
    func wireNames() throws {
        let activity = AgentActivity(kind: .awaitingInput, tool: .init(name: "Bash", startedAt: Date(timeIntervalSince1970: 0)), source: .hook)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(activity), as: UTF8.self)
        #expect(json == #"{"kind":"awaiting_input","source":"hook","tool":{"name":"Bash","started_at":"1970-01-01T00:00:00Z"}}"#)
        #expect(ResumeSafety.safe < .care && ResumeSafety.care < .risky)
        #expect(ResumeSafetyAssessment.Reason.betweenToolCalls.rawValue == "between_tool_calls")
    }
}
