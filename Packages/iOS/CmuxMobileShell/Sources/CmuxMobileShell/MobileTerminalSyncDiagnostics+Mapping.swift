import CMUXMobileCore

extension MobileTerminalSyncDiagnostics {
    enum ReplayTrigger: Int, Sendable {
        case coldAttach = 1, barrier = 2, droppedRenderGrid = 3, resync = 4
        case baseline = 5, viewport = 6, pendingInput = 7

        var analyticsValue: String {
            switch self {
            case .coldAttach: "cold_attach"
            case .barrier: "barrier"
            case .droppedRenderGrid: "dropped_render_grid"
            case .resync: "resync"
            case .baseline: "baseline"
            case .viewport: "viewport"
            case .pendingInput: "pending_input"
            }
        }
    }

    enum ReplayFailureReason: Int, Sendable {
        case rpcError = 1, empty = 2, staleSequence = 3, bytesNoSeq = 4
        case notDelivered = 5, pendingInputExhausted = 6, staleClient = 7
        case workspaceNotFound = 8, noRemoteClient = 9

        var analyticsValue: String {
            switch self {
            case .rpcError: "rpc_error"
            case .empty: "empty"
            case .staleSequence: "stale_sequence"
            case .bytesNoSeq: "bytes_no_seq"
            case .notDelivered: "not_delivered"
            case .pendingInputExhausted: "pending_input_exhausted"
            case .staleClient: "stale_client"
            case .workspaceNotFound: "workspace_not_found"
            case .noRemoteClient: "no_remote_client"
            }
        }
    }

    enum BarrierReason: Int, Sendable {
        case replayAck = 1, staleClient = 2, staleSequence = 3
        case pendingInputExhausted = 4, notDelivered = 5, empty = 6, bytesNoSeq = 7
        case viewportMissingGrid = 8, viewportUnchanged = 9, viewportFailed = 10
        case viewportStaleClient = 11, coldAttachFailed = 12, noRemoteClient = 13
        case workspaceNotFound = 14, failed = 15, resetReplayAck = 16, unknown = 17

        static func from(_ reason: String) -> BarrierReason {
            switch reason {
            case "replay_ack": .replayAck
            case "stale_client": .staleClient
            case "stale_sequence": .staleSequence
            case "pending_input_exhausted": .pendingInputExhausted
            case "not_delivered": .notDelivered
            case "empty": .empty
            case "bytes_no_seq": .bytesNoSeq
            case "viewport_missing_grid": .viewportMissingGrid
            case "viewport_unchanged": .viewportUnchanged
            case "viewport_failed": .viewportFailed
            case "viewport_stale_client": .viewportStaleClient
            case "cold_attach_failed": .coldAttachFailed
            case "no_remote_client": .noRemoteClient
            case "workspace_not_found": .workspaceNotFound
            case "failed": .failed
            case "reset_replay_ack": .resetReplayAck
            default: .unknown
            }
        }

        var stallRecoveryCause: TerminalStallRecoveryCause {
            switch self {
            case .replayAck, .resetReplayAck:
                .replayAck
            case .staleClient, .staleSequence, .pendingInputExhausted, .notDelivered,
                 .empty, .bytesNoSeq, .viewportMissingGrid, .viewportUnchanged,
                 .viewportFailed, .viewportStaleClient, .coldAttachFailed,
                 .noRemoteClient, .workspaceNotFound, .failed, .unknown:
                .barrierCleared
            }
        }
    }

    enum ViewportOutcome: Int, Sendable {
        case staleEchoRejected = 1, rearmExhausted = 2
        case leakedPreserved = 3, cancelledSuperseded = 4

        var analyticsValue: String {
            switch self {
            case .staleEchoRejected: "stale_echo_rejected"
            case .rearmExhausted: "rearm_exhausted"
            case .leakedPreserved: "leaked_preserved"
            case .cancelledSuperseded: "cancelled_superseded"
            }
        }
    }

    enum LivenessResult: Int, Sendable {
        case ok = 1, repaired = 2, failedResync = 3

        var analyticsValue: String {
            switch self {
            case .ok: "ok"
            case .repaired: "repaired"
            case .failedResync: "failed_resync"
            }
        }
    }

    enum ResyncTrigger: Int, Sendable {
        case liveness = 1, foreground = 2, networkChange = 3
        case manual = 4, inputSeqBehind = 5, streamEnded = 6, other = 7

        var analyticsValue: String {
            switch self {
            case .liveness: "liveness"
            case .foreground: "foreground"
            case .networkChange: "network_change"
            case .manual: "manual"
            case .inputSeqBehind: "input_seq_behind"
            case .streamEnded: "stream_ended"
            case .other: "other"
            }
        }

        static func from(reason: String) -> ResyncTrigger {
            if reason == "liveness" { return .liveness }
            if reason == "foreground" { return .foreground }
            if reason.contains("networkRecovery.networkChange") { return .networkChange }
            if reason.contains("networkRecovery.manual") { return .manual }
            if reason == "input_seq_behind" || reason == "seq_gap" { return .inputSeqBehind }
            if reason == "stream_ended" { return .streamEnded }
            return .other
        }
    }

    enum ManualRecoveryAction: Int, Sendable {
        case pullToRefresh = 1, reconnectTap = 2, renderReset = 3

        var analyticsValue: String {
            switch self {
            case .pullToRefresh: "pull_to_refresh"
            case .reconnectTap: "reconnect_tap"
            case .renderReset: "render_reset"
            }
        }
    }

    enum InputDropReason: Int, Sendable {
        case queueFull = 1, nonUTF8 = 2

        var analyticsValue: String {
            switch self {
            case .queueFull: "queue_full"
            case .nonUTF8: "non_utf8"
            }
        }
    }
}

extension TerminalRenderDropGate {
    var analyticsValue: String {
        switch self {
        case .pendingInputSeq: "pending_input_seq"
        case .replayBarrier: "replay_barrier"
        case .baselineWait: "baseline_wait"
        case .viewportBarrier: "viewport_barrier"
        }
    }
}

extension TerminalStallRecoveryCause {
    var analyticsValue: String {
        switch self {
        case .catchupFrame: "catchup_frame"
        case .replayAck: "replay_ack"
        case .resync: "resync"
        case .manualRefresh: "manual_refresh"
        case .reconnect: "reconnect"
        case .surfaceDetached: "surface_detached"
        case .barrierCleared: "barrier_cleared"
        }
    }
}
