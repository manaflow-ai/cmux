import CmuxNextCompat
import CmuxNextDevices
import CryptoKit
import Darwin
import Foundation

/// One channel to the Screen Sharing worker: requests with ids, answers matched by id, and
/// `push` events for a subscription. A dedicated thread reads it until it ends.
nonisolated final class RemoteDeviceChannel: Sendable {
    let socket: Int32
    private let state = Mutex(ChannelState())
    private let writeLock = Mutex(())
    static let timeout: TimeInterval = 10

    private struct ChannelState: @unchecked Sendable { // crash-allow: every field is read and written under the Mutex
        var open = true
        var nextID = 1
        var waiting: [Int: (Result<[String: Any], any Error>) -> Void] = [:]
        /// Hub pushes not read yet, and the one reader waiting for the next.
        var pushes: [String] = []
        var pushReader: CheckedContinuation<String?, Never>?
    }

    init(socket: Int32) {
        self.socket = socket
        let thread = Thread { [self] in readLoop() }
        thread.name = "cmux-remote-device"
        thread.start()
    }

    var isOpen: Bool { state.withLock { $0.open } }
    /// The next hub push, in order; nil once the channel ends. One reader at a time.
    func nextPush() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let ready = state.withLock { state -> String?? in
                if !state.pushes.isEmpty { return .some(state.pushes.removeFirst()) }
                guard state.open else { return .some(nil) }
                state.pushReader = continuation
                return .none
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    private func deliver(_ text: String) {
        let reader = state.withLock { state -> CheckedContinuation<String?, Never>? in
            if let reader = state.pushReader {
                state.pushReader = nil
                return reader
            }
            if state.pushes.count >= 256 { state.pushes.removeFirst() }
            state.pushes.append(text)
            return nil
        }
        reader?.resume(returning: text)
    }

    private func readLoop() {
        var pending = Data()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        // wakeup-allow: blocking read(2) on a dedicated thread; EOF ends it.
        while true {
            // concurrency-allow: a dedicated reader thread, never the main actor.
            let count = Darwin.read(socket, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            pending.append(contentsOf: bytes[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                if let id = object["id"] as? Int {
                    let done = state.withLock { $0.waiting.removeValue(forKey: id) }
                    if object["ok"] as? Bool == true {
                        done?(.success(object["result"] as? [String: Any] ?? [:]))
                    } else {
                        let message = (object["error"] as? [String: Any])?["message"] as? String ?? "refused"
                        done?(.failure(DeviceHubError.identity(message)))
                    }
                } else if object["event"] as? String == "push", let text = object["text"] as? String {
                    deliver(text)
                }
            }
        }
        let (waiting, reader) = state.withLock { state -> ([(Result<[String: Any], any Error>) -> Void], CheckedContinuation<String?, Never>?) in
            state.open = false
            defer {
                state.waiting.removeAll()
                state.pushReader = nil
            }
            return (Array(state.waiting.values), state.pushReader)
        }
        for done in waiting { done(.failure(DeviceHubError.transport("cmux Remote's channel closed"))) }
        reader?.resume(returning: nil)
        Darwin.close(socket)
    }

    private func send(_ method: String, _ params: [String: Any], done: @escaping (Result<[String: Any], any Error>) -> Void) {
        let id = state.withLock { state -> Int? in
            guard state.open else { return nil }
            let id = state.nextID
            state.nextID += 1
            state.waiting[id] = done
            return id
        }
        guard let id else { return done(.failure(DeviceHubError.transport("cmux Remote's channel closed"))) }
        var line = (try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])) ?? Data()
        line.append(0x0A)
        let written = writeLock.withLock { _ in RemoteSocket.writeAll(socket, line) }
        if !written, let done = state.withLock({ $0.waiting.removeValue(forKey: id) }) {
            done(.failure(DeviceHubError.transport("cmux Remote's channel closed")))
        }
    }

    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        nonisolated(unsafe) let params = params
        let answer: AnswerBox = try await withCheckedThrowingContinuation { continuation in
            send(method, params) { result in continuation.resume(with: result.map(AnswerBox.init)) }
        }
        return answer.value
    }

    func blockingCall(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        // concurrency-allow: DeviceKeyMaterial is synchronous; hub requests sign on the client actor and ticket signaling on its own tasks, never the main thread; the wait is bounded by `timeout`.
        let semaphore = DispatchSemaphore(value: 0)
        let box = Mutex<Result<AnswerBox, any Error>?>(nil)
        nonisolated(unsafe) let params = params
        send(method, params) { result in
            let boxed = result.map(AnswerBox.init)
            box.withLock { $0 = boxed }
            semaphore.signal()
        }
        guard semaphore.blockingWait(timeout: .now() + Self.timeout) == .success, let result = box.withLock({ $0 }) else {
            throw DeviceHubError.transport("cmux Remote did not answer \(method)")
        }
        return try result.get().value
    }

    func close() {
        _ = shutdown(socket, SHUT_RDWR)
    }
}

/// One answer, handed from the reader thread to its waiter.
nonisolated struct AnswerBox: @unchecked Sendable { // crash-allow: made by the reader thread, read once by the waiter
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

