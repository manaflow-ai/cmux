nonisolated enum ProcessSnapshotConsumer: String, Sendable {
    case memoryGuardrail = "memory_guardrail"
    case portScannerAgent = "port_scanner.agent"
    case portScannerPanel = "port_scanner.panel"
    case processDetectedResume = "process_detected_resume"
    case sentry = "sentry"
    case sharedLiveAgentIndex = "shared_live_agent_index"
    case systemTop = "system_top"
    case performanceExercisePrimary = "performance_exercise.primary"
    case performanceExerciseSecondary = "performance_exercise.secondary"
    case unspecified
}

nonisolated enum ProcessStaleRejection: String, Sendable {
    case portAgentAcknowledgement = "port_agent_acknowledgement"
    case portAgentRevision = "port_agent_revision"
    case portPanelRevision = "port_panel_revision"
}

nonisolated enum ProcessSnapshotReuseSource: String, Sendable {
    case cache
    case inFlight = "in_flight"
}

nonisolated enum ProcessLsofReuseSource: String, Sendable {
    case cache
    case inFlight = "in_flight"
}

nonisolated enum ProcessMeasuredOperation: String, Sendable {
    case portApply = "port.apply"
    case portFilter = "port.filter"
    case restorableApply = "restorable.apply"
    case restorableLoad = "restorable.load"
    case vaultFilter = "vault.filter"
}

nonisolated enum ProcessPerformanceCaptureBackend: String, Sendable {
    case libproc
    case subprocess
}

nonisolated struct ProcessPerformanceCaptureProof: Sendable, Equatable {
    let backend: ProcessPerformanceCaptureBackend
    let processLaunchCount: Int

    static let libproc = ProcessPerformanceCaptureProof(
        backend: .libproc,
        processLaunchCount: 0
    )
}
