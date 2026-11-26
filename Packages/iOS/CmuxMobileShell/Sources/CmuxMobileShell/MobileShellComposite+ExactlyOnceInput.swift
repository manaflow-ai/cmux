internal import CMUXMobileCore
internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
internal import CmuxMobileShellModel
internal import Foundation
internal import OSLog

private let exactlyOnceInputLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "terminal-input"
)

/// One unit of phone input bound to the terminal it was typed into.
struct MobileTerminalInputUnit: Sendable {
    enum Content: Sendable {
        case keys(String)
        case paste(String, submitKey: String)
        case image(Data, format: String)
    }

    var content: Content
    let workspaceID: MobileWorkspacePreview.ID
    let terminalID: MobileTerminalPreview.ID
    /// The newest correlated latency marker. The Mac reports a cumulative
    /// watermark, so it also covers the earlier ones.
    var marker: UInt64?

    /// Typed keys queued behind an in-flight request travel as one unit.
    static func merge(_ current: inout Self, _ next: Self) -> Bool {
        guard case .keys(let text) = current.content,
              case .keys(let more) = next.content,
              current.workspaceID == next.workspaceID,
              current.terminalID == next.terminalID,
              text.utf8.count + more.utf8.count <= MobileTerminalInputFrame.maximumInputBytes else {
            return false
        }
        current.content = .keys(text + more)
        current.marker = next.marker ?? current.marker
        return true
    }
}

typealias MobileTerminalInputUnitSender = MobileTerminalInputSender<MobileTerminalInputUnit>

extension MobileShellComposite {
    private static let exactlyOnceExplicitDeliveryTimeout: Duration = .seconds(10)

    // MARK: Identity

    /// The Mac identity a unit is bound to: canonical device plus instance
    /// tag, so two builds of cmux on one Mac never share an outbox.
    private static func exactlyOnceHostID(macDeviceID: String, instanceTag: String?) -> String {
        let key = MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
        return "\(key.canonicalMacDeviceID)|\(key.normalizedInstanceTag ?? "")"
    }

    /// The outbox a unit for this terminal joins, or nil when its Mac does not
    /// deliver input exactly once (older Macs and unidentified hosts keep the
    /// previous path).
    ///
    /// The Mac's live capability snapshot decides. While its connection is
    /// down, the verdict its last snapshot gave still applies, so input typed
    /// during a reconnect queues instead of being dropped; the next snapshot
    /// (including a downgraded build under the same identity) replaces it.
    func exactlyOnceInputKey(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) -> MobileTerminalInputUnitSender.Key? {
        guard let surfaceID = UUID(uuidString: terminalID.rawValue),
              let host = exactlyOnceHost(workspaceID: workspaceID) else {
            return nil
        }
        if let capabilities = host.liveCapabilities {
            if capabilities.contains(MobileTerminalInputDelivery.capability) {
                exactlyOnceInputHostIDs.insert(host.hostID)
            } else {
                exactlyOnceInputHostIDs.remove(host.hostID)
                // An identified unit must not cross a downgrade onto the
                // legacy path. Its outcome may be ambiguous, so settle the
                // existing stream as abandoned before new input falls back.
                exactlyOnceSender.abandon { $0.hostID == host.hostID }
            }
        }
        guard exactlyOnceInputHostIDs.contains(host.hostID) else { return nil }
        return MobileTerminalInputUnitSender.Key(hostID: host.hostID, surfaceID: surfaceID)
    }

    /// A Mac answered an identified unit without identifying it back: it was
    /// downgraded to a build without exactly-once delivery. Later units for it
    /// take the previous path.
    func noteHostLostExactlyOnceInput(_ hostID: String) {
        exactlyOnceInputHostIDs.remove(hostID)
    }

    /// The Mac a workspace row belongs to, from the row's own identity so it
    /// stays the same whether that Mac is foreground or secondary, plus the
    /// capability snapshot of its live connection (nil while it is down).
    private func exactlyOnceHost(
        workspaceID: MobileWorkspacePreview.ID
    ) -> (hostID: String, liveCapabilities: Set<String>?)? {
        let row = workspaces.first { $0.id == workspaceID }
        let target = workspaceMutationTarget(for: workspaceID)
        let rowDeviceID = row?.macDeviceID.flatMap { $0.isEmpty ? nil : $0 }
        guard let macDeviceID = rowDeviceID ?? target.macDeviceID, !macDeviceID.isEmpty,
              macDeviceID != Self.foregroundAnonymousKey else { return nil }
        let instanceTag = rowDeviceID != nil ? row?.macInstanceTag : activeMacInstanceTag
        let hostID = Self.exactlyOnceHostID(macDeviceID: macDeviceID, instanceTag: instanceTag)
        if target.isForeground {
            // While disconnected, the previous verdict still owns queued
            // input. Once connected, an empty capability snapshot is
            // authoritative: the host has downgraded or does not support the
            // identified-input protocol.
            let live = connectionState == .connected ? supportedHostCapabilities : nil
            return (hostID, live)
        }
        let capabilities = target.ownerKey.flatMap {
            secondaryMacSubscriptions[$0]?.supportedHostCapabilities
        }
        return (hostID, capabilities)
    }

    // MARK: Submitting

    /// Queues typed keys for exactly-once delivery. Returns false when the
    /// terminal's Mac does not support it and the caller keeps its old path.
    func submitExactlyOnceKeys(
        _ text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        marker: UInt64?,
        onSettled: @escaping MobileTerminalInputUnitSender.SettlementHandler
    ) -> SubmitOutcome {
        guard let key = exactlyOnceInputKey(workspaceID: workspaceID, terminalID: terminalID) else {
            return .unsupported
        }
        let unit = MobileTerminalInputUnit(
            content: .keys(text),
            workspaceID: workspaceID,
            terminalID: terminalID,
            marker: marker
        )
        return exactlyOnceSender.submit(
            unit,
            byteCount: text.utf8.count,
            to: key,
            onSettled: onSettled
        ) ? .queued : .full
    }

    enum SubmitOutcome {
        case queued
        case full
        case unsupported
    }

    /// Delivers one unit exactly once and waits for its settlement, or
    /// returns nil when its Mac does not support exactly-once input.
    func deliverExactlyOnce(
        _ content: MobileTerminalInputUnit.Content,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        byteCount: Int
    ) async -> MobileTerminalInputUnitSender.Settlement? {
        guard let key = exactlyOnceInputKey(workspaceID: workspaceID, terminalID: terminalID) else {
            return nil
        }
        let unit = MobileTerminalInputUnit(content: content, workspaceID: workspaceID, terminalID: terminalID)
        let timeoutTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: Self.exactlyOnceExplicitDeliveryTimeout)
            } catch {
                return
            }
            self?.exactlyOnceSender.abandon { $0 == key }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let accepted = exactlyOnceSender.submit(unit, byteCount: byteCount, to: key) { settlement in
                    timeoutTask.cancel()
                    continuation.resume(returning: settlement)
                }
                if !accepted {
                    timeoutTask.cancel()
                    continuation.resume(returning: .undeliverable)
                }
            }
        } onCancel: {
            timeoutTask.cancel()
            Task { @MainActor [weak self] in
                self?.exactlyOnceSender.abandon { $0 == key }
            }
        }
    }

    // MARK: Lifecycle

    /// Units whose path went away are sent again with their identity.
    func exactlyOnceInputPathsChanged() {
        exactlyOnceSender.resendUnacknowledged()
    }

    func exactlyOnceInputLaneReadinessChanged(surfaceID: String, ready: Bool) {
        guard let surface = UUID(uuidString: surfaceID) else { return }
        if ready {
            exactlyOnceSender.resume { $0.surfaceID == surface }
        } else {
            exactlyOnceSender.resendUnacknowledged { $0.surfaceID == surface }
        }
    }

    /// Sign-out: nothing queued for any Mac may be sent under the next account.
    func abandonExactlyOnceInput() {
        exactlyOnceSender.abandon { _ in true }
        exactlyOnceInputHostIDs.removeAll()
    }

    /// Moves undrained raw input into its terminals' outboxes before the
    /// focused connection changes, so a Mac switch never drops keystrokes.
    /// The adopted chunks' send-status operations join
    /// ``exactlyOnceOwnedSendOperationIDs``.
    func adoptUndrainedRawInputForExactlyOnceDelivery() {
        for chunk in takeUndrainedRawTerminalInput() {
            let operationID = chunk.sendStatusOperationID
            let outcome = submitExactlyOnceKeys(
                chunk.text,
                workspaceID: chunk.workspaceID,
                terminalID: chunk.terminalID,
                marker: nil
            ) { [weak self] settlement in
                self?.exactlyOnceKeysSettled(
                    settlement,
                    terminalID: chunk.terminalID.rawValue,
                    latencySequences: [],
                    latencyBatchNumber: nil,
                    sendStatusOperationID: operationID
                )
            }
            if outcome == .queued, let operationID {
                exactlyOnceOwnedSendOperationIDs.insert(operationID)
            }
        }
    }

    /// Reports the outcome of typed keys to the send-status indicator and
    /// the latency observer.
    func exactlyOnceKeysSettled(
        _ settlement: MobileTerminalInputUnitSender.Settlement,
        terminalID: String,
        latencySequences: [UInt64],
        latencyBatchNumber: UInt64?,
        sendStatusOperationID: UUID?
    ) {
        let delivered = settlement == .delivered
        for sequence in latencySequences {
            if delivered {
                terminalLatencyObserver.inputSent(surfaceID: terminalID, sequence: sequence)
            } else {
                terminalLatencyObserver.inputFailed(surfaceID: terminalID, sequence: sequence)
            }
        }
        #if DEBUG
        if let latencyBatchNumber {
            MobileLatencyTrace.stamp("in.settled", "n=\(latencyBatchNumber) ok=\(delivered ? 1 : 0)")
        }
        #endif
        if let sendStatusOperationID {
            exactlyOnceOwnedSendOperationIDs.remove(sendStatusOperationID)
        }
        finishExactlyOnceRawTerminalSend(sendStatusOperationID, forTerminalID: terminalID, succeeded: delivered)
        guard !delivered else { return }
        exactlyOnceInputLog.error(
            "terminal input not delivered surface=\(terminalID, privacy: .public) settlement=\(String(describing: settlement), privacy: .public)"
        )
        markTerminalInputUndelivered(terminalID: terminalID)
    }

    // MARK: Transport

    func makeExactlyOnceInputTransport() -> MobileTerminalInputUnitSender.Transport {
        MobileTerminalInputUnitSender.Transport(
            sendOnLane: { [weak self] key, unit, delivery in
                await self?.sendExactlyOnceOnLane(key: key, unit: unit, delivery: delivery) ?? .unavailable
            },
            sendOverRPC: { [weak self] key, unit, delivery in
                await self?.sendExactlyOnceOverRPC(key: key, unit: unit, delivery: delivery) ?? .unavailable
            },
            isReachable: { [weak self] key, unit in
                self?.exactlyOnceInputClient(key: key, unit: unit) != nil
            },
            pause: { attempt in
                let milliseconds = min(2_000, 50 << min(attempt, 6))
                try await ContinuousClock().sleep(for: .milliseconds(milliseconds))
            }
        )
    }

    /// The live client of the Mac this unit is bound to. Never another Mac's.
    private func exactlyOnceInputClient(
        key: MobileTerminalInputUnitSender.Key,
        unit: MobileTerminalInputUnit
    ) -> MobileCoreRPCClient? {
        guard let host = exactlyOnceHost(workspaceID: unit.workspaceID),
              host.hostID == key.hostID else { return nil }
        let target = workspaceMutationTarget(for: unit.workspaceID)
        if target.isForeground, connectionState != .connected { return nil }
        return target.client
    }

    private func sendExactlyOnceOnLane(
        key: MobileTerminalInputUnitSender.Key,
        unit: MobileTerminalInputUnit,
        delivery: MobileTerminalInputDelivery
    ) async -> MobileTerminalInputUnitSender.SendResult {
        // Lanes belong to the focused connection and carry typed keys only.
        guard case .keys(let text) = unit.content,
              text.utf8.count <= MobileTerminalInputFrame.maximumInputBytes,
              workspaceMutationTarget(for: unit.workspaceID).isForeground,
              exactlyOnceInputClient(key: key, unit: unit) != nil,
              let terminalLaneCoordinator else {
            return .unavailable
        }
        switch await terminalLaneCoordinator.sendInput(
            text,
            surfaceID: unit.terminalID.rawValue,
            sequence: unit.marker,
            delivery: delivery
        ) {
        case .sent: return .awaitingAcknowledgement
        case .failed: return .failed
        case .unavailable: return .unavailable
        }
    }

    private func sendExactlyOnceOverRPC(
        key: MobileTerminalInputUnitSender.Key,
        unit: MobileTerminalInputUnit,
        delivery: MobileTerminalInputDelivery
    ) async -> MobileTerminalInputUnitSender.SendResult {
        guard let client = exactlyOnceInputClient(key: key, unit: unit) else { return .unavailable }
        let generation = connectionGeneration
        let (method, parameters) = exactlyOnceRequest(unit, delivery: delivery)
        do {
            let response = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: method, params: parameters)
            )
            if isCurrentRemoteOperation(client: client, generation: generation) {
                handleExactlyOnceInputResponse(response, surfaceID: unit.terminalID.rawValue)
            }
            guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let acknowledgement = MobileTerminalInputAcknowledgement.fromRPC(payload: object) else {
                // Success without an acknowledgement: a Mac downgraded to a
                // build without exactly-once delivery wrote the unit the
                // legacy way. It is delivered; a resend would write it again.
                noteHostLostExactlyOnceInput(key.hostID)
                return .appliedWithoutIdentity
            }
            return .acknowledged(acknowledgement)
        } catch MobileShellConnectionError.rpcError(let code, let message) {
            exactlyOnceInputLog.error(
                "terminal input refused surface=\(unit.terminalID.rawValue, privacy: .public) code=\(code ?? "-", privacy: .public) message=\(message, privacy: .public)"
            )
            return .refused
        } catch {
            handleExactlyOnceTransportFailure(error, client: client, generation: generation)
            return .failed
        }
    }

    private func exactlyOnceRequest(
        _ unit: MobileTerminalInputUnit,
        delivery: MobileTerminalInputDelivery
    ) -> (method: String, parameters: [String: Any]) {
        var parameters: [String: Any] = [
            "workspace_id": remoteWorkspaceID(for: unit.workspaceID).rawValue,
            "surface_id": unit.terminalID.rawValue,
            "client_id": clientID,
        ]
        parameters.merge(delivery.rpcParameters) { current, _ in current }
        let method: String
        switch unit.content {
        case .keys(let text):
            method = "terminal.input"
            parameters["text"] = text
            parameters["input_sequence"] = unit.marker.map(String.init)
            parameters.merge(terminalViewportParameters(workspaceID: unit.workspaceID, terminalID: unit.terminalID)) { current, _ in current }
        case .paste(let text, let submitKey):
            method = "terminal.paste"
            parameters["text"] = text
            parameters["submit_key"] = submitKey
            parameters.merge(terminalViewportParameters(workspaceID: unit.workspaceID, terminalID: unit.terminalID)) { current, _ in current }
        case .image(let data, let format):
            method = "terminal.paste_image"
            parameters["image_base64"] = data.base64EncodedString()
            parameters["image_format"] = format
        }
        return (method, parameters)
    }
}
