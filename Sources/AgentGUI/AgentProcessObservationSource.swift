import CmuxAgentReplica
import CmuxAgentTruthKit
import Foundation

@MainActor
final class AgentProcessObservationSource {
    private var timer: DispatchSourceTimer?
    private let utilityQueue = DispatchQueue(label: "dev.cmux.agentgui.process-observation", qos: .utility)
    private let onObservations: @MainActor ([ProcessObservation]) -> Void

    init(onObservations: @escaping @MainActor ([ProcessObservation]) -> Void) {
        self.onObservations = onObservations
    }

    func setRunning(_ shouldRun: Bool) {
        if shouldRun {
            start()
        } else {
            stop()
        }
    }

    func scanNow() {
        let capture = Task.detached(priority: .utility) {
            await Self.captureObservations()
        }
        Task { @MainActor [onObservations] in
            onObservations(await capture.value)
        }
    }

    private func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: utilityQueue)
        timer.schedule(deadline: .now(), repeating: AgentGUIConstants.observationCadence)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scanNow()
            }
        }
        self.timer = timer
        timer.resume()
    }

    private func stop() {
        timer?.cancel()
        timer = nil
    }

    private nonisolated static func captureObservations() async -> [ProcessObservation] {
        let snapshot = await CmuxTopProcessSnapshotStore.shared.snapshot(
            requirements: [.processDetails, .cmuxScope],
            maximumAge: 1
        )
        return snapshot.cmuxScopedProcesses().compactMap { process in
            observation(for: process)
        }
    }

    private nonisolated static func observation(for process: CmuxTopProcessInfo) -> ProcessObservation? {
        guard let details = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: process.pid) else {
            return nil
        }
        let kind = agentKind(arguments: details.arguments, environment: details.environment, processName: process.name)
        guard kind.rawValue == "claude" || kind.rawValue == "codex" else {
            return nil
        }
        let identity = AgentPIDProcessIdentity(pid: pid_t(process.pid))
        let startTick = identity.map { Int($0.startSeconds &* 1_000_000 &+ $0.startMicroseconds) } ?? process.pid
        let cwd = normalized(details.environment["CMUX_AGENT_LAUNCH_CWD"] ?? details.environment["PWD"]) ?? ""
        let surfaceID = process.cmuxSurfaceID?.uuidString
            ?? normalized(details.environment["CMUX_SURFACE_ID"])
            ?? normalized(details.environment["CMUX_PANEL_ID"])
        let argvSummary = details.arguments.prefix(3).joined(separator: " ")
        return ProcessObservation(
            pid: Int32(process.pid),
            ppid: Int32(process.parentPID),
            startTick: startTick,
            argvSummary: argvSummary.isEmpty ? process.name : argvSummary,
            agentKindGuess: kind,
            cwd: cwd,
            surfaceID: surfaceID,
            openTranscriptPath: AgentGUIOpenTranscriptPathScanner.transcriptPath(pid: Int32(process.pid), kind: kind.rawValue)
        )
    }

    nonisolated static func agentKind(arguments: [String], environment: [String: String], processName _: String) -> AgentKind {
        if let launchKind = normalized(environment["CMUX_AGENT_LAUNCH_KIND"]) {
            return AgentKind(rawValue: launchKind)
        }
        guard let executable = arguments.first else {
            return .unknown("unknown")
        }
        let executableName = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        var candidateNames = [executableName]
        let runtimeLaunchers = Set(["node", "bun", "deno", "python", "python3", "sh", "bash", "zsh"])
        if runtimeLaunchers.contains(executableName),
           let launchedPath = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            candidateNames.append(URL(fileURLWithPath: launchedPath).lastPathComponent.lowercased())
        }
        if candidateNames.contains("claude") {
            return .claude
        }
        if candidateNames.contains("codex") {
            return .codex
        }
        return .unknown("unknown")
    }

    private nonisolated static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
