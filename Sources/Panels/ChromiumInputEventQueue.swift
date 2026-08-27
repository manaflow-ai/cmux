import CmuxBrowser
import Foundation

/// Serializes native input events before they cross the Chromium session
/// actor. Pointer motion is coalesced under pressure, while key and button
/// transitions retain FIFO order; when a queue contains only transitions,
/// new input is rejected rather than evicting an older transition.
@MainActor
final class ChromiumInputEventQueue {
    enum Event: Sendable {
        case mouse(
            type: String,
            x: Double,
            y: Double,
            button: String,
            clickCount: Int,
            deltaX: Double,
            deltaY: Double
        )
        case key(
            type: String,
            key: String,
            code: String,
            text: String?,
            modifiers: Int,
            windowsVirtualKeyCode: Int
        )

        var isCoalescable: Bool {
            if case .mouse(let type, _, _, _, _, _, _) = self {
                return type == "mouseMoved" || type == "mouseWheel"
            }
            return false
        }
    }

    private let session: ChromiumBrowserSession
    private var pending: [Event] = []
    private var worker: Task<Void, Never>?
    /// Identity of the currently installed worker. A canceled worker may
    /// still resume after a replacement has started, so it may clear only its
    /// own generation's reference.
    private var workerGeneration: UInt64?
    private var nextWorkerGeneration: UInt64 = 0
    private let maximumPendingEvents = 512

    var onFailure: ((any Error) -> Void)?

    init(session: ChromiumBrowserSession) {
        self.session = session
    }

    func enqueue(_ event: Event) {
        if pending.count >= maximumPendingEvents {
            if let motionIndex = pending.firstIndex(where: { $0.isCoalescable }) {
                pending.remove(at: motionIndex)
            } else {
                // Never evict a key/button transition: dropping one side of a
                // press/release pair leaves Chromium's input state latched.
                // The bounded queue applies backpressure by rejecting this
                // newest event until the worker drains an existing transition.
                return
            }
        }
        pending.append(event)
        startWorkerIfNeeded()
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        workerGeneration = nil
        pending.removeAll(keepingCapacity: false)
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        nextWorkerGeneration &+= 1
        let generation = nextWorkerGeneration
        workerGeneration = generation
        worker = Task { @MainActor [weak self, generation] in
            guard let self else { return }
            while !Task.isCancelled,
                  self.workerGeneration == generation,
                  !self.pending.isEmpty {
                let event = pending.removeFirst()
                do {
                    try await dispatch(event)
                } catch {
                    guard self.workerGeneration == generation else { return }
                    onFailure?(error)
                }
            }
            guard self.workerGeneration == generation else { return }
            worker = nil
            workerGeneration = nil
            if !pending.isEmpty, !Task.isCancelled {
                startWorkerIfNeeded()
            }
        }
    }

    private func dispatch(_ event: Event) async throws {
        switch event {
        case .mouse(let type, let x, let y, let button, let clickCount, let deltaX, let deltaY):
            try await session.dispatchMouse(
                type: type,
                x: x,
                y: y,
                button: button,
                clickCount: clickCount,
                deltaX: deltaX,
                deltaY: deltaY
            )
        case .key(let type, let key, let code, let text, let modifiers, let windowsVirtualKeyCode):
            try await session.dispatchKey(
                type: type,
                key: key,
                code: code,
                text: text,
                modifiers: modifiers,
                windowsVirtualKeyCode: windowsVirtualKeyCode
            )
        }
    }
}
