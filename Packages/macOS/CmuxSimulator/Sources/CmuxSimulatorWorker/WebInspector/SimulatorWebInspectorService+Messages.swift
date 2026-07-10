import CmuxSimulator
import Foundation

extension SimulatorWebInspectorService {
    func receive(propertyListBody: Data) {
        let message: [String: Any]
        do {
            message = try SimulatorWebInspectorPlistFrameCodec.decodeBody(propertyListBody)
        } catch {
            eventHandler?(.failure(error as? SimulatorWebInspectorError ?? .invalidPropertyList))
            return
        }
        guard let selector = message["__selector"] as? String else { return }

        if catalog.apply(message, ownConnectionIdentifier: connectionIdentifier) {
            handleCatalogChange(selector: selector, message: message)
            eventHandler?(.targets(catalog.targets))
            validateAttachedTarget()
        }
        if selector == "_rpc_applicationSentData:" {
            receiveForwardedData(message)
        }
    }

    func sendToTarget(_ data: Data) throws {
        guard let session else { throw SimulatorWebInspectorError.sessionUnavailable }
        guard data.count <= SimulatorWebInspectorSessionRouter.maximumCommandLength else {
            throw SimulatorWebInspectorError.commandTooLarge(data.count)
        }
        try sendRPC(selector: "_rpc_forwardSocketData:", arguments: [
            "WIRApplicationIdentifierKey": session.target.applicationIdentifier,
            "WIRPageIdentifierKey": NSNumber(value: session.target.pageIdentifier),
            "WIRSenderKey": session.senderIdentifier,
            "WIRSocketDataKey": data,
        ])
        guard socket != nil else { throw SimulatorWebInspectorError.transportClosed }
    }

    func callTarget(
        method: String,
        parameters: [String: Any] = [:]
    ) async throws -> [String: Any] {
        try await performInternalRequest(
            method: method,
            parameters: parameters,
            bypassRouter: false
        )
    }

    func callTopLevel(
        method: String,
        parameters: [String: Any] = [:]
    ) async throws -> [String: Any] {
        try await performInternalRequest(
            method: method,
            parameters: parameters,
            bypassRouter: true
        )
    }

    func negotiateSessionRouting() async throws {
        do {
            _ = try await callTopLevel(method: "Runtime.enable")
            guard var session else { throw SimulatorWebInspectorError.sessionUnavailable }
            let queued = session.router.selectLegacyMode()
            self.session = session
            for message in queued { try sendToTarget(message) }
        } catch let error as SimulatorWebInspectorError {
            if session?.router.mode == .targetBased { return }
            guard case .remoteCommand = error else { throw error }
            try await waitForTargetBasedSignal()
        }
    }

    func finishRoutingNegotiation() {
        guard let continuation = routingContinuation else { return }
        routingContinuation = nil
        routingTimeoutTask?.cancel()
        routingTimeoutTask = nil
        continuation.resume()
    }

    func failRoutingNegotiation(with error: Error) {
        guard let continuation = routingContinuation else { return }
        routingContinuation = nil
        routingTimeoutTask?.cancel()
        routingTimeoutTask = nil
        continuation.resume(throwing: error)
    }

    private func performInternalRequest(
        method: String,
        parameters: [String: Any],
        bypassRouter: Bool
    ) async throws -> [String: Any] {
        guard session != nil else { throw SimulatorWebInspectorError.sessionUnavailable }
        let identifier = nextInternalRequestIdentifier
        nextInternalRequestIdentifier = identifier == Int64.min
            ? -9_000_000_000_000_000
            : identifier - 1
        let request = try JSONSerialization.data(withJSONObject: [
            "id": identifier,
            "method": method,
            "params": parameters,
        ])

        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingInternalRequests[identifier] = continuation
                internalRequestTimeoutTasks[identifier] = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.sleeper.sleep(for: .seconds(5))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self.failInternalRequest(
                        identifier,
                        with: SimulatorWebInspectorError.timedOut(method)
                    )
                }
                do {
                    if bypassRouter {
                        try sendToTarget(request)
                    } else {
                        try sendMessage(String(decoding: request, as: UTF8.self))
                    }
                } catch {
                    failInternalRequest(identifier, with: error)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.failInternalRequest(identifier, with: CancellationError())
            }
        }
        let value = try JSONSerialization.jsonObject(with: response)
        guard let dictionary = value as? [String: Any] else {
            throw SimulatorWebInspectorError.invalidMessage
        }
        if let error = dictionary["error"] as? [String: Any] {
            throw SimulatorWebInspectorError.remoteCommand(
                error["message"] as? String ?? "Web Inspector rejected \(method)."
            )
        }
        return dictionary
    }

    private func waitForTargetBasedSignal() async throws {
        if session?.router.mode == .targetBased { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                routingContinuation = continuation
                routingTimeoutTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.sleeper.sleep(for: .seconds(5))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self.failRoutingNegotiation(
                        with: SimulatorWebInspectorError.timedOut("target routing negotiation")
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.failRoutingNegotiation(with: CancellationError())
            }
        }
    }

    func transportEnded(error: Error = SimulatorWebInspectorError.transportClosed) {
        guard socket != nil else { return }
        let closingSocket = socket
        socket = nil
        socketReaderTask?.cancel()
        socketReaderTask = nil
        closingSocket?.close()
        currentDeviceIdentifier = nil
        cancelRefresh(with: error)
        releaseSession(emit: true)
        catalog.reset()
        subscribedApplicationIdentifiers.removeAll()
        pendingListingIdentifiers.removeAll()
        eventHandler?(.targets([]))
        eventHandler?(.failure(error as? SimulatorWebInspectorError ?? .transportClosed))
    }

    func failInternalRequests(with error: Error) {
        let identifiers = Array(pendingInternalRequests.keys)
        for identifier in identifiers { failInternalRequest(identifier, with: error) }
    }

    private func handleCatalogChange(selector: String, message: [String: Any]) {
        let argument = message["__argument"] as? [String: Any] ?? [:]
        switch selector {
        case "_rpc_reportConnectedApplicationList:":
            let identifiers = Set(catalog.inspectableApplicationIdentifiers)
            subscribedApplicationIdentifiers.formUnion(identifiers)
            pendingListingIdentifiers = identifiers
            for identifier in identifiers { requestListing(applicationIdentifier: identifier) }
            if identifiers.isEmpty { finishRefresh() }
        case "_rpc_applicationConnected:":
            guard let identifier = argument["WIRApplicationIdentifierKey"] as? String,
                  catalog.inspectableApplicationIdentifiers.contains(identifier) else { return }
            subscribedApplicationIdentifiers.insert(identifier)
            pendingListingIdentifiers.insert(identifier)
            requestListing(applicationIdentifier: identifier)
        case "_rpc_applicationDisconnected:":
            guard let identifier = argument["WIRApplicationIdentifierKey"] as? String else { return }
            subscribedApplicationIdentifiers.remove(identifier)
            pendingListingIdentifiers.remove(identifier)
            if pendingListingIdentifiers.isEmpty { finishRefresh() }
        case "_rpc_applicationSentListing:":
            guard let identifier = argument["WIRApplicationIdentifierKey"] as? String else { return }
            pendingListingIdentifiers.remove(identifier)
            if pendingListingIdentifiers.isEmpty { finishRefresh() }
        default:
            break
        }
    }

    private func requestListing(applicationIdentifier: String) {
        try? sendRPC(selector: "_rpc_forwardGetListing:", arguments: [
            "WIRApplicationIdentifierKey": applicationIdentifier,
        ])
    }

    private func validateAttachedTarget() {
        guard let session else { return }
        guard let current = catalog.target(id: session.target.id), !current.isInUse else {
            releaseSession()
            return
        }
    }

    private func receiveForwardedData(_ message: [String: Any]) {
        guard var session,
              let argument = message["__argument"] as? [String: Any],
              destinationMatches(argument, session: session),
              let data = forwardedData(argument) else { return }
        let result = session.router.routeIncoming(data)
        let negotiatedTargetBased = session.router.mode == .targetBased
        self.session = session
        if negotiatedTargetBased { finishRoutingNegotiation() }
        for outgoing in result.messagesForTarget { try? sendToTarget(outgoing) }
        for incoming in result.messagesForHost {
            if completeInternalRequest(with: incoming) { continue }
            emitRawMessage(incoming, sessionID: session.identifier)
        }
    }

    private func destinationMatches(_ argument: [String: Any], session: Session) -> Bool {
        if let destination = argument["WIRDestinationKey"] as? String,
           destination != session.senderIdentifier { return false }
        guard argument["WIRApplicationIdentifierKey"] as? String
                == session.target.applicationIdentifier else { return false }
        if let page = Self.integer(argument["WIRPageIdentifierKey"]),
           page >= 0,
           UInt64(page) != session.target.pageIdentifier { return false }
        return true
    }

    private func forwardedData(_ argument: [String: Any]) -> Data? {
        let value = argument["WIRMessageDataKey"] ?? argument["WIRSocketDataKey"]
        if let data = value as? Data { return data }
        if let string = value as? String { return Data(string.utf8) }
        return nil
    }

    private func emitRawMessage(_ data: Data, sessionID: UUID) {
        let messageID = UUID()
        let maximum = SimulatorWebInspectorMessageChunker.defaultMaximumPayloadLength
        if data.isEmpty {
            eventHandler?(.message(SimulatorWebInspectorMessageChunk(
                sessionID: sessionID,
                messageID: messageID,
                sequence: 0,
                isFinal: true,
                payload: Data()
            )))
            return
        }
        var offset = 0
        var sequence = 0
        while offset < data.count {
            let end = min(offset + maximum, data.count)
            eventHandler?(.message(SimulatorWebInspectorMessageChunk(
                sessionID: sessionID,
                messageID: messageID,
                sequence: sequence,
                isFinal: end == data.count,
                payload: data.subdata(in: offset..<end)
            )))
            offset = end
            sequence += 1
        }
    }

    private func completeInternalRequest(with data: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let dictionary = value as? [String: Any],
              let identifier = Self.integer(dictionary["id"]),
              let continuation = pendingInternalRequests.removeValue(forKey: identifier)
        else { return false }
        internalRequestTimeoutTasks.removeValue(forKey: identifier)?.cancel()
        continuation.resume(returning: data)
        return true
    }

    private func failInternalRequest(_ identifier: Int64, with error: Error) {
        guard let continuation = pendingInternalRequests.removeValue(forKey: identifier) else {
            return
        }
        internalRequestTimeoutTasks.removeValue(forKey: identifier)?.cancel()
        continuation.resume(throwing: error)
    }
}
