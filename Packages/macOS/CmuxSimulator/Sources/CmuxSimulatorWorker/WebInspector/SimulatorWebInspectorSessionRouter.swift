import Foundation
import CoreFoundation

struct SimulatorWebInspectorSessionRouter {
    typealias Mode = SimulatorWebInspectorSessionMode
    typealias IncomingResult = SimulatorWebInspectorIncomingResult
    private typealias RequestIdentifier = SimulatorWebInspectorRequestIdentifier

    private(set) var innerTargetIdentifier: String?
    private(set) var mode: Mode = .negotiating
    private var wrappedAcknowledgementCounts: [RequestIdentifier: Int] = [:]
    private var wrappedAcknowledgementCount = 0
    private var wrapperIdentifierPrefix = UUID().uuidString
    private var nextWrapperIdentifier: UInt64 = 0
    private var queuedMessages: [Data] = []
    private var queuedByteCount = 0

    static let maximumCommandLength = 1024 * 1024
    static let maximumQueuedCommandCount = 64
    static let maximumQueuedByteCount = 2 * 1024 * 1024
    static let maximumWrappedAcknowledgementCount = 1_024

    mutating func routeOutgoing(_ raw: Data) throws -> [Data] {
        guard raw.count <= Self.maximumCommandLength else {
            throw SimulatorWebInspectorError.commandTooLarge(raw.count)
        }
        let message = try simulatorWebInspectorJSONObject(raw)
        let method = message["method"] as? String
        let isTargetDomain = method?.hasPrefix("Target.") == true

        if isTargetDomain,
           let identifier = simulatorWebInspectorRequestIdentifier(message["id"]),
           wrappedAcknowledgementCounts[identifier] != nil {
            throw SimulatorWebInspectorError.wrapperIdentifierCollision
        }

        if mode == .targetBased, let innerTargetIdentifier, !isTargetDomain {
            guard wrappedAcknowledgementCount < Self.maximumWrappedAcknowledgementCount else {
                throw SimulatorWebInspectorError.wrapperAcknowledgementBacklog(
                    wrappedAcknowledgementCount
                )
            }
            let wrapperIdentifier = makeWrapperIdentifier()
            wrappedAcknowledgementCounts[wrapperIdentifier] = 1
            wrappedAcknowledgementCount += 1
            var parameters: [String: Any] = [
                "message": String(decoding: raw, as: UTF8.self),
                "targetId": innerTargetIdentifier,
            ]
            if let identifier = message["id"] { parameters["id"] = identifier }
            let wrapped: [String: Any] = [
                "id": wrapperIdentifier.foundationValue,
                "method": "Target.sendMessageToTarget",
                "params": parameters,
            ]
            return [try JSONSerialization.data(withJSONObject: wrapped)]
        }

        if mode == .negotiating, !isTargetDomain {
            guard queuedMessages.count < Self.maximumQueuedCommandCount,
                  queuedByteCount + raw.count <= Self.maximumQueuedByteCount else {
                throw SimulatorWebInspectorError.commandTooLarge(queuedByteCount + raw.count)
            }
            queuedMessages.append(raw)
            queuedByteCount += raw.count
            return []
        }
        if mode == .targetBased, innerTargetIdentifier == nil, !isTargetDomain {
            return try enqueue(raw)
        }
        return [raw]
    }

    mutating func routeIncoming(_ raw: Data) -> IncomingResult {
        routeIncoming(raw, isFromTarget: false)
    }

    private mutating func routeIncoming(
        _ raw: Data,
        isFromTarget: Bool
    ) -> IncomingResult {
        guard let message = try? simulatorWebInspectorJSONObject(raw) else {
            return IncomingResult(messagesForHost: [raw])
        }
        let method = message["method"] as? String
        switch method {
        case "Target.targetCreated":
            if innerTargetIdentifier == nil,
               let parameters = message["params"] as? [String: Any],
               let info = parameters["targetInfo"] as? [String: Any],
               info["type"] as? String == "page",
               let identifier = info["targetId"] as? String {
                mode = .targetBased
                innerTargetIdentifier = identifier
                return IncomingResult(messagesForTarget: flushQueuedForTarget())
            }
            return IncomingResult()
        case "Target.didCommitProvisionalTarget":
            if let parameters = message["params"] as? [String: Any],
               let identifier = parameters["newTargetId"] as? String {
                mode = .targetBased
                innerTargetIdentifier = identifier
                return IncomingResult(messagesForTarget: flushQueuedForTarget())
            }
            return IncomingResult()
        case "Target.targetDestroyed":
            if let parameters = message["params"] as? [String: Any],
               let identifier = parameters["targetId"] as? String,
               identifier == innerTargetIdentifier {
                innerTargetIdentifier = nil
            }
            return IncomingResult()
        case "Target.dispatchMessageFromTarget":
            guard let parameters = message["params"] as? [String: Any],
                  let inner = parameters["message"] as? String else {
                return IncomingResult()
            }
            return routeIncoming(Data(inner.utf8), isFromTarget: true)
        default:
            break
        }

        if !isFromTarget,
           let identifier = simulatorWebInspectorRequestIdentifier(message["id"]),
           consumeWrappedAcknowledgement(identifier) {
            return IncomingResult()
        }
        return IncomingResult(messagesForHost: [raw])
    }

    mutating func selectLegacyMode() -> [Data] {
        guard mode == .negotiating else { return [] }
        mode = .legacy
        let messages = queuedMessages
        queuedMessages.removeAll(keepingCapacity: true)
        queuedByteCount = 0
        return messages
    }

    mutating func selectTargetBasedMode(targetIdentifier: String) -> [Data] {
        mode = .targetBased
        innerTargetIdentifier = targetIdentifier
        return flushQueuedForTarget()
    }

    mutating func reset() {
        innerTargetIdentifier = nil
        mode = .negotiating
        wrappedAcknowledgementCounts.removeAll()
        wrappedAcknowledgementCount = 0
        wrapperIdentifierPrefix = UUID().uuidString
        nextWrapperIdentifier = 0
        queuedMessages.removeAll()
        queuedByteCount = 0
    }

    private mutating func flushQueuedForTarget() -> [Data] {
        let queued = queuedMessages
        queuedMessages.removeAll(keepingCapacity: true)
        queuedByteCount = 0
        var result: [Data] = []
        for message in queued {
            if let routed = try? routeOutgoing(message) { result.append(contentsOf: routed) }
        }
        return result
    }

    private mutating func enqueue(_ raw: Data) throws -> [Data] {
        guard wrappedAcknowledgementCount + queuedMessages.count
                    < Self.maximumWrappedAcknowledgementCount else {
            throw SimulatorWebInspectorError.wrapperAcknowledgementBacklog(
                wrappedAcknowledgementCount + queuedMessages.count
            )
        }
        guard queuedMessages.count < Self.maximumQueuedCommandCount,
              queuedByteCount + raw.count <= Self.maximumQueuedByteCount else {
            throw SimulatorWebInspectorError.commandTooLarge(queuedByteCount + raw.count)
        }
        queuedMessages.append(raw)
        queuedByteCount += raw.count
        return []
    }

    private mutating func makeWrapperIdentifier() -> RequestIdentifier {
        defer { nextWrapperIdentifier &+= 1 }
        return .string("cmux-wrapper-\(wrapperIdentifierPrefix)-\(nextWrapperIdentifier)")
    }

    private mutating func consumeWrappedAcknowledgement(
        _ identifier: RequestIdentifier
    ) -> Bool {
        guard let count = wrappedAcknowledgementCounts[identifier], count > 0 else {
            return false
        }
        if count == 1 { wrappedAcknowledgementCounts.removeValue(forKey: identifier) }
        else { wrappedAcknowledgementCounts[identifier] = count - 1 }
        wrappedAcknowledgementCount -= 1
        return true
    }
}

private func simulatorWebInspectorJSONObject(_ data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = object as? [String: Any] else {
        throw SimulatorWebInspectorError.invalidMessage
    }
    return dictionary
}

private func simulatorWebInspectorRequestIdentifier(
    _ value: Any?
) -> SimulatorWebInspectorRequestIdentifier? {
    if let value = value as? String { return .string(value) }
    if let number = value as? NSNumber,
       CFGetTypeID(number) != CFBooleanGetTypeID() {
        return .number(number.stringValue)
    }
    return nil
}
