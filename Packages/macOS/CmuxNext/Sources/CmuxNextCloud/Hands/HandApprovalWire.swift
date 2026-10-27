public import Foundation
import CmuxNextWakeups
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The owner's user socket (`/v1/wire/user`, `cmux.wire/1`) read for the hand frames only
/// (docs/chief-hands.md): `hand-approval-pending {hand, id, summary, at, sign}` and
/// `hand-approval-settled {hand, id, outcome}`. The frames are ephemeral (no replay), so each
/// subscribe answer (`connected`) tells the service to read the waiting list again. The bearer goes
/// in the Authorization header; reconnects back off.
@MainActor
final class HandApprovalWire {
    enum Event: Sendable {
        /// Subscribed (also after a reconnect): read the waiting approvals now.
        case connected
        case pending(HandApproval)
        case settled(hand: String, id: String, outcome: HandApprovalOutcome)
    }

    private let url: URL
    private let token: @Sendable () async throws -> String
    private var runner: Task<Void, Never>?
    private var generation = 0

    init(apiBaseURL: URL, token: @escaping @Sendable () async throws -> String) {
        var c = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.path = "/v1/wire/user"
        url = c.url ?? apiBaseURL
        self.token = token
    }

    func start(_ sink: @escaping @MainActor (Event) -> Void) {
        stop()
        let generation = generation
        runner = Task { [weak self] in await self?.run(generation, sink: sink) }
    }

    func stop() {
        generation += 1
        runner?.cancel()
        runner = nil
    }

    private func run(_ generation: Int, sink: @escaping @MainActor (Event) -> Void) async {
        var backoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))
        // wakeup-allow: backoff: one pass per connection; each pass awaits the socket and, after a failure, a Backoff delay.
        while !Task.isCancelled, generation == self.generation {
            do {
                try await session(generation, sink: sink, onSubscribed: { backoff.reset() })
            } catch is CancellationError {
                return
            } catch {}
            // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
            do { try await backoff.wait(owner: "hands.wire.reconnect") } catch { return }
        }
    }

    private func session(_ generation: Int, sink: @MainActor (Event) -> Void, onSubscribed: () -> Void) async throws {
        var request = URLRequest(url: url)
        request.setValue("cmux.wire.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        // updates.minimumVersion: an owner refuses a client that does not name its version.
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            request.setValue(version, forHTTPHeaderField: "x-cmux-client-version")
        }
        let task = URLSession.shared.webSocketTask(with: request)
        // The subscribe answer is the user owner's snapshot (up to about 1.5 MB).
        task.maximumMessageSize = 8 << 20
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        // receive() ignores task cancellation: stop() closes the socket, so a stopped run posts nothing more.
        try await withTaskCancellationHandler {
            // wakeup-allow: bounded: each turn awaits the next frame; a closed socket throws and ends the loop.
            while !Task.isCancelled {
                let message = try await task.receive()
                let data: Data
                switch message {
                case let .string(text): data = Data(text.utf8)
                case let .data(bytes): data = bytes
                @unknown default: continue
                }
                let frame = await Task.detached(priority: Task.currentPriority) { Frame.decode(data) }.value
                guard generation == self.generation else { throw CancellationError() }
                switch frame {
                case .welcome:
                    try await task.send(.string(#"{"t":"subscribe"}"#))
                case .snapshot:
                    onSubscribed()
                    sink(.connected)
                case let .event(event):
                    sink(event)
                case .ignored:
                    break
                }
            }
            throw CancellationError()
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    /// One frame, decoded off the main actor (a snapshot is large; only its type is read).
    nonisolated enum Frame: Sendable {
        case welcome, snapshot, ignored
        case event(Event)

        static func decode(_ data: Data) -> Frame {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .ignored }
            switch object["t"] as? String {
            case "welcome": return .welcome
            case "snapshot": return .snapshot
            case "hand-approval-pending":
                return HandApproval(object).map { .event(.pending($0)) } ?? .ignored
            case "hand-approval-settled":
                guard let hand = object["hand"] as? String, HandIDs.isHand(hand), let id = object["id"] as? String,
                      HandIDs.isApproval(id), let outcome = (object["outcome"] as? String).flatMap(HandApprovalOutcome.init(rawValue:))
                else { return .ignored }
                return .event(.settled(hand: hand, id: id, outcome: outcome))
            default: return .ignored
            }
        }
    }
}
