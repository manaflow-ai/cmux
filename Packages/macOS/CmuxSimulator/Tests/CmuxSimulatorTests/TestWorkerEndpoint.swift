import Foundation
@testable import CmuxSimulator

final class TestWorkerEndpoint: @unchecked Sendable {
    let processIdentifier: Int32?
    private let lock = NSLock()
    private let continuation: AsyncStream<Data>.Continuation
    private let stream: AsyncStream<Data>
    private let sentMessageContinuation: AsyncStream<Void>.Continuation
    private let sentMessageStream: AsyncStream<Void>
    private var sentData: [Data] = []
    private var responder: (@Sendable (SimulatorWorkerInbound) -> SimulatorWorkerOutbound?)?
    private var nextSendFailure: (@Sendable (SimulatorWorkerInbound) -> Bool)?

    init(processIdentifier: Int32? = nil) {
        self.processIdentifier = processIdentifier
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        self.stream = stream
        self.continuation = continuation
        let (sentMessageStream, sentMessageContinuation) = AsyncStream.makeStream(of: Void.self)
        self.sentMessageStream = sentMessageStream
        self.sentMessageContinuation = sentMessageContinuation
    }

    var connection: SimulatorWorkerConnection {
        SimulatorWorkerConnection(
            processIdentifier: processIdentifier,
            messages: stream,
            send: { [weak self] data in try self?.append(data) },
            closeInput: { [weak self] in self?.finish() },
            terminate: { [weak self] in self?.terminate() },
            terminalFailure: { nil }
        )
    }

    private(set) var terminationCount = 0

    func terminate() {
        lock.withLock { terminationCount += 1 }
        finish()
    }

    func terminationCountValue() -> Int {
        lock.withLock { terminationCount }
    }

    func finish() {
        continuation.finish()
    }

    func emit(_ message: SimulatorWorkerOutbound) {
        if let data = try? JSONEncoder().encode(message) {
            continuation.yield(data)
        }
    }

    func setResponder(
        _ responder: @escaping @Sendable (SimulatorWorkerInbound) -> SimulatorWorkerOutbound?
    ) {
        lock.lock()
        self.responder = responder
        lock.unlock()
    }

    func inboundMessages() -> [SimulatorWorkerInbound] {
        lock.lock()
        let data = sentData
        lock.unlock()
        return data.compactMap { try? JSONDecoder().decode(SimulatorWorkerInbound.self, from: $0) }
    }

    func waitForInboundMessages(
        timeout: Duration = .seconds(5),
        until predicate: @escaping @Sendable ([SimulatorWorkerInbound]) -> Bool
    ) async -> [SimulatorWorkerInbound]? {
        let current = inboundMessages()
        if predicate(current) { return current }
        return await withTaskGroup(of: [SimulatorWorkerInbound]?.self) { group in
            group.addTask { [sentMessageStream] in
                for await _ in sentMessageStream {
                    let messages = self.inboundMessages()
                    if predicate(messages) { return messages }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    func acknowledgeRecordedPings() {
        for sequence in inboundMessages().compactMap({ message -> UInt64? in
            guard case let .ping(sequence) = message else { return nil }
            return sequence
        }) {
            emit(.ack(sequence))
        }
    }

    func failNextSend(
        where predicate: @escaping @Sendable (SimulatorWorkerInbound) -> Bool
    ) {
        lock.withLock { nextSendFailure = predicate }
    }

    private func append(_ data: Data) throws {
        let message = try JSONDecoder().decode(SimulatorWorkerInbound.self, from: data)
        lock.lock()
        if let nextSendFailure, nextSendFailure(message) {
            self.nextSendFailure = nil
            lock.unlock()
            throw SimulatorChannelError.writeFailed
        }
        sentData.append(data)
        let responder = self.responder
        lock.unlock()
        sentMessageContinuation.yield()
        guard let response = responder?(message),
              let responseData = try? JSONEncoder().encode(response) else { return }
        continuation.yield(responseData)
    }
}
