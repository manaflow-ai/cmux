import CMUXMobileCore
internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
internal import CmuxMobileShellModel
import Foundation
internal import OSLog

nonisolated private let terminalEventStreamLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    func recordTerminalManualRecovery(
        action: MobileTerminalSyncDiagnostics.ManualRecoveryAction,
        surfaceID requestedSurfaceID: String? = nil
    ) {
        let surfaceID = requestedSurfaceID
            ?? selectedTerminalID?.rawValue
            ?? terminalByteContinuationsBySurfaceID.keys.sorted().first
        let surfaceHandle = surfaceID.map(Self.diagnosticSurfaceHandle)
        let gateMask: Int
        let retryCount: Int
        let pendingInputWait: Bool
        let replayInFlight: Bool
        let ackSeqGap: Int?
        if let surfaceID {
            var mask = 0
            if pendingTerminalByteEndSeqBySurfaceID[surfaceID] != nil {
                mask |= TerminalRenderDropGate.pendingInputSeq.bit
            }
            if terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil {
                mask |= TerminalRenderDropGate.replayBarrier.bit
            }
            if terminalRenderGridBaselineReplayBarrierTokensBySurfaceID[surfaceID] != nil {
                mask |= TerminalRenderDropGate.baselineWait.bit
            }
            if terminalViewportReplayBarrierPendingAckTokensBySurfaceID[surfaceID] != nil {
                mask |= TerminalRenderDropGate.viewportBarrier.bit
            }
            gateMask = mask
            retryCount = terminalReplayFailureRetryCountsBySurfaceID[surfaceID] ?? 0
            pendingInputWait = pendingTerminalByteEndSeqBySurfaceID[surfaceID] != nil
            replayInFlight = terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            if let pendingSeq = pendingTerminalByteEndSeqBySurfaceID[surfaceID] {
                let localSeq = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0
                ackSeqGap = Int(clamping: pendingSeq > localSeq ? pendingSeq - localSeq : 0)
            } else {
                ackSeqGap = nil
            }
        } else {
            gateMask = 0
            retryCount = 0
            pendingInputWait = false
            replayInFlight = false
            ackSeqGap = nil
        }
        let now = runtime?.now() ?? Date()
        let watchdogSilentMs = lastTerminalEventAt.map {
            Int(max(0, now.timeIntervalSince($0) * 1000))
        } ?? 0
        terminalSyncDiagnostics.manualRecoverySnapshot(
            surface: surfaceHandle,
            action: action,
            gatesActive: gateMask,
            pendingInputWait: pendingInputWait,
            replayInFlight: replayInFlight,
            replayRetryCount: retryCount,
            secondsSinceLastAppliedFrame: terminalSyncDiagnostics.secondsSinceLastAppliedFrame(surface: surfaceHandle),
            watchdogSilentMs: watchdogSilentMs,
            transport: terminalOutputTransport.debugName,
            ackSeqGap: ackSeqGap
        )
    }

    func startRenderGridLivenessWatchdog(listenerID: UUID) {
        stopRenderGridLivenessWatchdog(listenerID: nil)
        renderGridLivenessListenerID = listenerID
        recordTerminalEventStreamLiveness()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = Self.renderGridLivenessCheckInterval
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.checkRenderGridLiveness(listenerID: listenerID)
            }
        }
        renderGridLivenessTimer = timer
        timer.resume()
    }

    func stopRenderGridLivenessWatchdog(listenerID: UUID?) {
        if let listenerID, renderGridLivenessListenerID != listenerID {
            return
        }
        renderGridLivenessTimer?.cancel()
        renderGridLivenessTimer = nil
        renderGridLivenessListenerID = nil
        renderGridLivenessProbeTask?.cancel()
        renderGridLivenessProbeTask = nil
        renderGridLivenessProbeID = nil
    }

    func recordTerminalEventStreamLiveness() {
        lastTerminalEventAt = runtime?.now() ?? Date()
    }

    func checkRenderGridLiveness(listenerID: UUID) {
        guard renderGridLivenessListenerID == listenerID else { return }
        guard let client = remoteClient, connectionState == .connected else { return }
        guard terminalEventListenerID == listenerID else { return }
        let now = runtime?.now() ?? Date()
        let last = lastTerminalEventAt ?? now
        let silent = now.timeIntervalSince(last)
        guard silent >= Self.renderGridLivenessSilenceThreshold else { return }
        guard renderGridLivenessProbeTask == nil else { return }
        let probeTimeoutNanoseconds = runtime?.livenessProbeTimeoutNanoseconds
            ?? 3_000_000_000
        let topics = terminalOutputTransport.eventTopics
        let probeID = UUID()
        renderGridLivenessProbeID = probeID
        renderGridLivenessProbeTask = Task { @MainActor [weak self] in
            let ack = await self?.probeEventSubscriptionLiveness(
                client: client,
                topics: topics,
                timeoutNanoseconds: probeTimeoutNanoseconds
            ) ?? .failed
            guard let self else { return }
            guard self.renderGridLivenessProbeID == probeID else { return }
            self.renderGridLivenessProbeTask = nil
            self.renderGridLivenessProbeID = nil
            guard !Task.isCancelled,
                  self.renderGridLivenessListenerID == listenerID,
                  self.terminalEventListenerID == listenerID,
                  self.remoteClient === client,
                  self.connectionState == .connected else { return }
            if case .subscribed(let alreadySubscribed) = ack {
                self.recordTerminalEventStreamLiveness()
                self.markMacConnectionHealthy()
                let silentMs = Int(silent * 1000)
                if alreadySubscribed == false {
                    MobileDebugLog.anchormux("sync.liveness probe_repaired silentMs=\(silentMs)")
                    self.terminalSyncDiagnostics.livenessProbe(result: .repaired, silentMs: silentMs)
                    terminalEventStreamLog.info("liveness probe reinstalled a lost event subscription, replaying mounted surfaces")
                    for surfaceID in self.terminalByteContinuationsBySurfaceID.keys {
                        self.requestTerminalReplay(surfaceID: surfaceID, trigger: .resync)
                    }
                    self.scheduleWorkspaceListRefreshFromEvent()
                } else {
                    MobileDebugLog.anchormux("sync.liveness probe_ok silentMs=\(silentMs)")
                    self.terminalSyncDiagnostics.livenessProbe(result: .ok, silentMs: silentMs)
                }
                return
            }
            let recheckNow = self.runtime?.now() ?? Date()
            let recheckLast = self.lastTerminalEventAt ?? recheckNow
            guard recheckNow.timeIntervalSince(recheckLast) >= Self.renderGridLivenessSilenceThreshold else {
                return
            }
            let silentMs = Int(recheckNow.timeIntervalSince(recheckLast) * 1000)
            MobileDebugLog.anchormux("sync.liveness re-subscribe silentMs=\(silentMs)")
            self.diagnosticLog?.record(DiagnosticEvent(.livenessResubscribe, ms: UInt32(clamping: silentMs)))
            self.terminalSyncDiagnostics.livenessProbe(result: .failedResync, silentMs: silentMs)
            terminalEventStreamLog.info("render-grid stream silent for \(silentMs, privacy: .public)ms and subscription probe failed, re-subscribing")
            self.resyncTerminalOutput(reason: "liveness", restartEventStream: true)
        }
    }

    private func probeEventSubscriptionLiveness(
        client: MobileCoreRPCClient,
        topics: [String],
        timeoutNanoseconds: UInt64
    ) async -> TerminalEventSubscriptionAck {
        let probe = Task { @MainActor [weak self] in
            await self?.requestTerminalEventSubscription(
                client: client,
                reason: "liveness_probe",
                topics: topics
            ) ?? .failed
        }
        let deadline = DispatchSource.makeTimerSource(queue: .main)
        deadline.schedule(deadline: .now() + .nanoseconds(Int(clamping: timeoutNanoseconds)))
        deadline.setEventHandler { probe.cancel() }
        deadline.resume()
        let ack = await probe.value
        deadline.cancel()
        return ack
    }

    func resyncTerminalOutput(
        reason: String,
        restartEventStream: Bool,
        surfaceIDs requestedSurfaceIDs: [String]? = nil
    ) {
        guard remoteClient != nil, connectionState == .connected else { return }
        let surfaceIDs = requestedSurfaceIDs ?? Array(terminalByteContinuationsBySurfaceID.keys)
        terminalSyncDiagnostics.resyncTriggered(
            trigger: .from(reason: reason),
            restartedStream: restartEventStream,
            surfaceCount: surfaceIDs.count
        )
        if restartEventStream {
            stopTerminalRefreshPolling()
            startTerminalRefreshPolling()
        } else if terminalEventListenerTask == nil {
            startTerminalRefreshPolling()
        } else {
            refreshTerminalEventSubscription(reason: reason)
        }

        MobileDebugLog.anchormux(
            "sync.resync reason=\(reason) restart=\(restartEventStream) surfaces=\(surfaceIDs.count)"
        )
        for surfaceID in surfaceIDs {
            requestTerminalReplay(surfaceID: surfaceID, trigger: .resync)
        }
    }

    func handleTerminalInputResponse(_ data: Data, surfaceID: String) {
        guard hasTerminalOutputSink(surfaceID: surfaceID),
              let payload = try? MobileTerminalInputResponse.decode(data),
              let remoteSeq = payload.terminalSeq else {
            return
        }
        let localSeq = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0
        guard remoteSeq > localSeq else { return }
        let canRenderGridAdvancePendingSeq = terminalOutputTransport == .renderGrid
            || (terminalOutputTransport == .hybrid && terminalActiveScreenBySurfaceID[surfaceID] == .alternate)
        if canRenderGridAdvancePendingSeq, terminalEventListenerTask != nil {
            let previousPendingSeq = pendingTerminalByteEndSeqBySurfaceID[surfaceID]
            let targetSeq = max(remoteSeq, pendingTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0)
            if let previousPendingSeq {
                guard targetSeq > previousPendingSeq else {
                    if pendingTerminalInputDroppedRenderGridSurfaceIDs.contains(surfaceID) {
                        MobileDebugLog.anchormux(
                            "sync.input_seq_replay_after_drop surface=\(surfaceID) local=\(localSeq) pending=\(targetSeq) remote=\(remoteSeq)"
                        )
                        requestTerminalReplayAfterDroppedRenderGrid(surfaceID: surfaceID, source: "input_ack")
                    }
                    return
                }
            }
            if previousPendingSeq == nil {
                terminalReplayFailureRetryCountsBySurfaceID.removeValue(forKey: surfaceID)
            }
            pendingTerminalByteEndSeqBySurfaceID[surfaceID] = targetSeq
            MobileDebugLog.anchormux("sync.input_seq_wait surface=\(surfaceID) local=\(localSeq) pending=\(targetSeq) remote=\(remoteSeq)")
            refreshTerminalEventSubscription(reason: "input_seq_wait")
            return
        }
        MobileDebugLog.anchormux("sync.input_seq_behind surface=\(surfaceID) local=\(localSeq) remote=\(remoteSeq)")
        diagnosticLog?.record(DiagnosticEvent(
            .inputSeqBehind,
            surface: Self.diagnosticSurfaceHandle(surfaceID),
            a: Int(clamping: localSeq),
            b: Int(clamping: remoteSeq)
        ))
        terminalEventStreamLog.info("terminal output behind after input surface=\(surfaceID, privacy: .public) localSeq=\(localSeq, privacy: .public) remoteSeq=\(remoteSeq, privacy: .public)")
        resyncTerminalOutput(
            reason: "input_seq_behind",
            restartEventStream: false,
            surfaceIDs: [surfaceID]
        )
    }
}
