import CmuxNextCompat
import CmuxNextDevices
import Darwin
import Foundation

/// One channel to the Screen Sharing worker: requests with ids, answers matched by id, and
/// `push` events for a subscription. A dedicated thread reads it until it ends. Answers cross
/// threads as raw JSON lines (`Data`) and are parsed by their waiter.
nonisolated final class RemoteDeviceChannel: Sendable {
    typealias Waiter = @Sendable (Result<Data, any Error>) -> Void

    let socket: Int32
    private let state = Mutex(ChannelState())
    private let writeLock = Mutex(())
    static let timeout: TimeInterval = 10
    /// The most hub pushes kept for a reader that has not asked yet.
    static let pushLimit = 256

    private struct ChannelState: Sendable {
        var open = true
        var nextID = 1
        var waiting: [Int: Waiter] = [:]
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
            if state.pushes.count >= Self.pushLimit { state.pushes.removeFirst() }
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
                    done?(.success(line))
                } else if object["event"] as? String == "push", let text = object["text"] as? String {
                    deliver(text)
                }
            }
        }
        let (waiting, reader) = state.withLock { state -> ([Waiter], CheckedContinuation<String?, Never>?) in
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

    /// Sends one request line (`params` already encoded as a JSON object); `done` gets its answer line.
    private func send(_ method: String, _ params: Data, done: @escaping Waiter) {
        let id = state.withLock { state -> Int? in
            guard state.open else { return nil }
            let id = state.nextID
            state.nextID += 1
            state.waiting[id] = done
            return id
        }
        guard let id else { return done(.failure(DeviceHubError.transport("cmux Remote's channel closed"))) }
        var line = Data(#"{"id":\#(id),"method":"#.utf8)
        line.append((try? JSONSerialization.data(withJSONObject: method, options: .fragmentsAllowed)) ?? Data(#""""#.utf8))
        line.append(Data(#","params":"#.utf8))
        line.append(params)
        line.append(Data("}\n".utf8))
        let written = writeLock.withLock { _ in RemoteSocket.writeAll(socket, line) }
        if !written, let done = state.withLock({ $0.waiting.removeValue(forKey: id) }) {
            done(.failure(DeviceHubError.transport("cmux Remote's channel closed")))
        }
    }

    /// An answer line's `result`, or its error.
    static func result(_ line: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw DeviceHubError.transport("cmux Remote's answer is not JSON")
        }
        guard object["ok"] as? Bool == true else {
            throw DeviceHubError.identity((object["error"] as? [String: Any])?["message"] as? String ?? "refused")
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    static func encode(_ params: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
    }

    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let encoded = Self.encode(params)
        let line: Data = try await withCheckedThrowingContinuation { continuation in
            send(method, encoded) { continuation.resume(with: $0) }
        }
        return try Self.result(line)
    }

    func blockingCall(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Mutex<Result<Data, any Error>?>(nil)
        send(method, Self.encode(params)) { result in
            box.withLock { $0 = result }
            semaphore.signal()
        }
        // DeviceKeyMaterial is synchronous: hub requests sign on the client's actor and ticket
        // signaling on its own tasks, never the main thread; the wait is bounded by `timeout`.
        guard semaphore.blockingWait(timeout: .now() + Self.timeout) == .success, let result = box.withLock({ $0 }) else {
            throw DeviceHubError.transport("cmux Remote did not answer \(method)")
        }
        return try Self.result(result.get())
    }

    func close() {
        _ = shutdown(socket, SHUT_RDWR)
    }
}
