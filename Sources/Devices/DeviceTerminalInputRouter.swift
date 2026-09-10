import CmuxTerminal
import Foundation

/// Delivers keystrokes from a manual-mirror Ghostty surface to another Mac's
/// terminal in order, one `mobile.terminal.input` request at a time.
///
/// Ghostty's I/O thread hands input to `enqueue` off the main actor; the router
/// serializes it into a queue the main-actor drain reads. Bytes that arrive
/// while a request is in flight are coalesced into the next request, so fast
/// typing over a slow link costs one round trip per burst, not per key.
final class DeviceTerminalInputRouter: @unchecked Sendable {
    enum InputError: Error, LocalizedError {
        case queueFull
        case invalidEncoding

        var errorDescription: String? {
            switch self {
            case .queueFull:
                return String(localized: "devices.input.queueFull", defaultValue: "Some terminal input was not sent because the connection could not keep up. Wait and try again.")
            case .invalidEncoding:
                return String(localized: "devices.input.invalidEncoding", defaultValue: "Some terminal input was not sent because this Mac requires UTF-8 text.")
            }
        }
    }

    // @unchecked Sendable: `pending` and `draining` are only touched under
    // `queue`; callers cross the boundary with immutable Data values.
    private let queue = DispatchQueue(label: "dev.cmux.devices.terminal-input", qos: .userInitiated)
    private var pending = Data()
    private var draining = false
    private var invalidated = false
    private let pendingByteLimit = 256 * 1024
    private let send: @Sendable (Data) async throws -> Void
    private let onFailure: @Sendable (any Error) -> Void

    init(
        send: @escaping @Sendable (Data) async throws -> Void,
        onFailure: @escaping @Sendable (any Error) -> Void
    ) {
        self.send = send
        self.onFailure = onFailure
    }

    /// Safe from Ghostty's I/O thread. Named keys never reach the host: with no
    /// key-name resolver installed, Ghostty encodes every key to bytes itself.
    func enqueue(_ input: TerminalManualInput) {
        guard case .bytes(let data) = input, !data.isEmpty else { return }
        queue.async { [self] in
            guard !invalidated else { return }
            guard pending.count + data.count <= pendingByteLimit else {
                onFailure(InputError.queueFull)
                return
            }
            pending.append(data)
            guard !draining else { return }
            draining = true
            Task { await self.drain() }
        }
    }

    func invalidate() {
        queue.async { [self] in
            invalidated = true
            pending.removeAll()
        }
    }

    private func takePending() -> Data? {
        queue.sync {
            guard !invalidated, !pending.isEmpty else {
                draining = false
                return nil
            }
            let batch = pending
            pending = Data()
            return batch
        }
    }

    private func drain() async {
        while let batch = takePending() {
            do {
                try await send(batch)
            } catch {
                onFailure(error)
                queue.sync {
                    pending.removeAll()
                    draining = false
                }
                return
            }
        }
    }
}
