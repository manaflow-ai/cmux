import CmuxAgentReplica
@testable import CmuxAgentTruthKit
import Testing

@Suite(.serialized)
@MainActor
struct AgentTruthReducerTests {
    @Test
    func phaseRulesAndHealing() {
        let reducer = AgentTruthReducer(macDeviceID: MacDeviceID(rawValue: "mac"))
        let sessionID = AgentSessionID(rawValue: "real-session")

        let observed = reducer.fold(.processObserved(process(surface: "surface-a", startTick: 10), tick: 1))
        #expect(upsertedPhases(observed) == [.starting])

        let start = reducer.fold(.hookEvent(hook(sessionID: sessionID, eventName: .sessionStart), tick: 2))
        #expect(start.contains(.sessionRemoved(AgentSessionID(rawValue: "prov:surface-a:10"))))
        #expect(lastUpsert(start)?.phase == .idle)

        #expect(lastUpsert(reducer.fold(.hookEvent(hook(sessionID: sessionID, eventName: .userPromptSubmit), tick: 3)))?.phase == .working)
        #expect(lastUpsert(reducer.fold(.hookEvent(hook(sessionID: sessionID, eventName: .permissionRequest), tick: 4)))?.phase == .needsInput)
        #expect(lastUpsert(reducer.fold(.hookEvent(hook(sessionID: sessionID, eventName: .notification, notificationRequiresInput: true), tick: 5)))?.phase == .needsInput)
        #expect(lastUpsert(reducer.fold(.hookEvent(hook(sessionID: sessionID, eventName: .stop), tick: 6)))?.phase == .idle)
        #expect(lastUpsert(reducer.fold(.hookEvent(hook(sessionID: sessionID, eventName: .notification, notificationRequiresInput: false), tick: 7)))?.phase == .idle)

        let beforeSubagent = reducer.snapshots[sessionID]?.version
        #expect(reducer.fold(.hookEvent(hook(sessionID: sessionID, eventName: .subagentStop), tick: 8)).isEmpty)
        #expect(reducer.snapshots[sessionID]?.version == beforeSubagent)

        #expect(lastUpsert(reducer.fold(.hookEvent(hook(sessionID: sessionID, eventName: .userPromptSubmit), tick: 9)))?.phase == .working)
        #expect(lastUpsert(reducer.fold(.transcriptCorroboration(sessionID: sessionID, fact: .assistantTurnCompleted, tick: 10)))?.phase == .idle)
        #expect(lastUpsert(reducer.fold(.transcriptCorroboration(sessionID: sessionID, fact: .userMessageAppended, tick: 11)))?.phase == .working)
        #expect(lastUpsert(reducer.fold(.hookEvent(hook(sessionID: sessionID, eventName: .sessionEnd), tick: 12)))?.phase == .ended)
        #expect(lastUpsert(reducer.fold(.processGone(pid: 100, startTick: 10, tick: 13)))?.phase == .ended)
        #expect(lastUpsert(reducer.fold(.processObserved(process(surface: "surface-a", startTick: 10), tick: 14)))?.phase == .idle)
        #expect(lastUpsert(reducer.fold(.wrapperLaunched(wrapper(sessionID: sessionID, launchArgvKind: .resume), tick: 15)))?.phase == .idle)
    }

    @Test
    func provisionalMergePreservesVersionContinuityAndSurfaceBoundary() {
        let reducer = AgentTruthReducer(macDeviceID: MacDeviceID(rawValue: "mac"))
        let real = AgentSessionID(rawValue: "real")
        let provisional = AgentSessionID(rawValue: "prov:surface-a:20")

        _ = reducer.fold(.processObserved(process(surface: "surface-a", startTick: 20), tick: 1))
        #expect(reducer.snapshots[provisional]?.version == EntityVersion(rawValue: 1))

        let wrongSurface = reducer.fold(.hookEvent(hook(sessionID: real, eventName: .sessionStart, surfaceID: "surface-b"), tick: 2))
        #expect(!wrongSurface.contains(.sessionRemoved(provisional)))
        #expect(reducer.snapshots[provisional] != nil)

        let merge = reducer.fold(.hookEvent(hook(sessionID: real, eventName: .sessionStart), tick: 3))
        #expect(merge.contains(.sessionRemoved(provisional)))
        #expect(merge.filter { if case .sessionUpserted = $0 { true } else { false } }.count == 1)
        #expect(reducer.snapshots[provisional] == nil)
        #expect(reducer.snapshots[real]?.version == EntityVersion(rawValue: 2))
    }

    @Test
    func sameTickMergeEmitsUpsertEvenWhenHookRefinementNoOps() {
        let reducer = AgentTruthReducer(macDeviceID: MacDeviceID(rawValue: "mac"))
        let real = AgentSessionID(rawValue: "real")
        let provisional = AgentSessionID(rawValue: "prov:surface-a:50")

        _ = reducer.fold(.hookEvent(hook(sessionID: real, eventName: .sessionStart, pid: nil), tick: 1))
        _ = reducer.fold(.processObserved(process(surface: "surface-a", startTick: 50), tick: 2))
        let changes = reducer.fold(.hookEvent(hook(sessionID: real, eventName: .sessionStart), tick: 1))

        #expect(changes.contains(.sessionRemoved(provisional)))
        #expect(lastUpsert(changes)?.id == real)
        #expect(lastUpsert(changes)?.version == EntityVersion(rawValue: 2))
        #expect(reducer.evidence[real]?.hasProcessObservation == true)
    }

    @Test
    func tierTransitionsAndNoOpFolds() {
        let reducer = AgentTruthReducer(macDeviceID: MacDeviceID(rawValue: "mac"))
        let sessionID = AgentSessionID(rawValue: "real")

        _ = reducer.fold(.processObserved(process(surface: "surface-a", startTick: 30), tick: 1))
        #expect(reducer.snapshots[AgentSessionID(rawValue: "prov:surface-a:30")]?.tier == .observed)

        _ = reducer.fold(.wrapperLaunched(wrapper(sessionID: sessionID), tick: 2))
        #expect(reducer.snapshots[sessionID]?.tier == .wrapped)

        let version = reducer.snapshots[sessionID]?.version
        #expect(reducer.fold(.wrapperLaunched(wrapper(sessionID: sessionID), tick: 2)).isEmpty)
        #expect(reducer.snapshots[sessionID]?.version == version)

        _ = reducer.fold(.wrapperLaunched(wrapper(sessionID: sessionID, socketWasDown: true), tick: 3))
        #expect(reducer.snapshots[sessionID]?.tier == .degraded)

        let capabilityID = AgentSessionID(rawValue: "capability")
        _ = reducer.fold(.wrapperLaunched(wrapper(
            sessionID: capabilityID,
            cliVersion: "0.128",
            minimumCLIVersion: "0.139",
            hooksUnavailableSafeMode: true
        ), tick: 4))
        #expect(reducer.evidence[capabilityID]?.reasons.contains(.cliVersionBelowMinimum(found: "0.128", minimum: "0.139")) == true)
        #expect(reducer.evidence[capabilityID]?.reasons.contains(.hooksUnavailableSafeMode) == true)

        let hookedID = AgentSessionID(rawValue: "hooked")
        _ = reducer.fold(.hookEvent(hook(sessionID: hookedID, eventName: .sessionStart, pid: 101), tick: 5))
        #expect(reducer.snapshots[hookedID]?.tier == .hooked)

        let conflictID = AgentSessionID(rawValue: "conflict")
        _ = reducer.fold(.wrapperLaunched(wrapper(sessionID: conflictID, pid: 102), tick: 6))
        _ = reducer.fold(.hookEvent(hook(sessionID: conflictID, eventName: .sessionStart, surfaceID: "surface-a", pid: 103), tick: 7))
        #expect(reducer.snapshots[conflictID]?.tier == .degraded)
    }

    @Test
    func processGoneRequiresPidAndStartIdentity() {
        let reducer = AgentTruthReducer(macDeviceID: MacDeviceID(rawValue: "mac"))
        let provisional = AgentSessionID(rawValue: "prov:surface-a:40")
        _ = reducer.fold(.processObserved(process(surface: "surface-a", startTick: 40), tick: 1))

        #expect(reducer.fold(.processGone(pid: 100, startTick: 41, tick: 2)).isEmpty)
        #expect(reducer.snapshots[provisional]?.phase == .starting)
        #expect(lastUpsert(reducer.fold(.processGone(pid: 100, startTick: 40, tick: 3)))?.phase == .ended)
    }

    @Test
    func wrapperLaunchedSessionCanEndBeforeProcessObservation() {
        let reducer = AgentTruthReducer(macDeviceID: MacDeviceID(rawValue: "mac"))
        let sessionID = AgentSessionID(rawValue: "wrapper-only")

        _ = reducer.fold(.wrapperLaunched(wrapper(sessionID: sessionID), tick: 1))
        #expect(lastUpsert(reducer.fold(.processGone(pid: 100, startTick: 999, tick: 2)))?.phase == .ended)
    }

    private func process(pid: Int32 = 100, surface: String, startTick: Int) -> ProcessObservation {
        ProcessObservation(
            pid: pid,
            ppid: 10,
            startTick: startTick,
            argvSummary: "codex",
            agentKindGuess: .codex,
            cwd: "/tmp/example",
            surfaceID: surface,
            openTranscriptPath: nil
        )
    }

    private func wrapper(
        sessionID: AgentSessionID?,
        pid: Int32 = 100,
        launchArgvKind: LaunchArgvKind = .new,
        socketWasDown: Bool = false,
        cliVersion: String? = nil,
        minimumCLIVersion: String? = nil,
        hooksUnavailableSafeMode: Bool = false
    ) -> WrapperLaunchFact {
        WrapperLaunchFact(
            surfaceID: "surface-a",
            agentKind: .codex,
            pid: pid,
            cwd: "/tmp/example",
            sessionID: sessionID,
            launchArgvKind: launchArgvKind,
            socketWasDown: socketWasDown,
            hooksUnavailableSafeMode: hooksUnavailableSafeMode,
            cliVersion: cliVersion,
            minimumCLIVersion: minimumCLIVersion
        )
    }

    private func hook(
        sessionID: AgentSessionID,
        eventName: HookEventName,
        surfaceID: String? = "surface-a",
        pid: Int32? = 100,
        notificationRequiresInput: Bool = false
    ) -> HookFact {
        HookFact(
            sessionID: sessionID,
            eventName: eventName,
            surfaceID: surfaceID,
            transcriptPath: "/tmp/example/transcript.jsonl",
            cwd: "/tmp/example",
            pid: pid,
            notificationRequiresInput: notificationRequiresInput
        )
    }

    private func upsertedPhases(_ changes: [AgentTruthChange]) -> [SessionPhase] {
        changes.compactMap { change in
            if case .sessionUpserted(let snapshot) = change {
                snapshot.phase
            } else {
                nil
            }
        }
    }

    private func lastUpsert(_ changes: [AgentTruthChange]) -> AgentSessionSnapshot? {
        changes.compactMap { change in
            if case .sessionUpserted(let snapshot) = change {
                snapshot
            } else {
                nil
            }
        }.last
    }
}
