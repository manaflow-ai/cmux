import CmuxBrowser
import Foundation

/// Serializes native input events before they cross the Chromium session
/// actor. Pointer motion is coalesced under pressure, while key and button
/// transitions retain FIFO order; when a queue contains only transitions,
/// new input is rejected rather than evicting an older transition.
@MainActor
final class ChromiumInputEventQueue {
    enum ReleaseIdentity: Hashable, Sendable {
        case key(code: String)
        case mouse(button: String)
    }

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

        var releaseIdentity: ReleaseIdentity? {
            switch self {
            case .key(let type, _, let code, _, _, _) where type == "keyUp":
                return .key(code: code)
            case .mouse(let type, _, _, let button, _, _, _) where type == "mouseReleased":
                return .mouse(button: button)
            default:
                return nil
            }
        }
    }

    private let session: ChromiumBrowserSession
    private var pending: [Event] = []
    /// Releases that arrive after the ordinary queue is full are held in a
    /// separate bounded FIFO and drained after already-queued presses.
    private var pendingReleaseEvents: [Event] = []
    private var pendingReleaseIdentities: Set<ReleaseIdentity> = []
    private var worker: Task<Void, Never>?
    /// Identity of the currently installed worker. A canceled worker may
    /// still resume after a replacement has started, so it may clear only its
    /// own generation's reference.
    private var workerGeneration: UInt64?
    private var nextWorkerGeneration: UInt64 = 0
    private let maximumPendingEvents = 512
    private let maximumPendingReleaseEvents = 256
    private var didFailClosedForOverflow = false
    private var overflowResetTask: Task<Void, Never>?

    var onFailure: ((any Error) -> Void)?

    init(session: ChromiumBrowserSession) {
        self.session = session
    }

    func enqueue(_ event: Event) {
        guard !didFailClosedForOverflow else { return }
        if pending.count >= maximumPendingEvents {
            if let motionIndex = pending.firstIndex(where: { $0.isCoalescable }) {
                pending.remove(at: motionIndex)
            } else if let releaseIdentity = event.releaseIdentity {
                // Keep each release identity at most once while the ordinary
                // FIFO drains. Duplicate releases do not change browser state
                // and would only consume the emergency capacity.
                guard pendingReleaseIdentities.insert(releaseIdentity).inserted else {
                    return
                }
                guard pendingReleaseEvents.count < maximumPendingReleaseEvents else {
                    beginFailClosedForOverflow()
                    return
                }
                pendingReleaseEvents.append(event)
                startWorkerIfNeeded()
                return
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
        overflowResetTask?.cancel()
        worker = nil
        workerGeneration = nil
        overflowResetTask = nil
        didFailClosedForOverflow = false
        pending.removeAll(keepingCapacity: false)
        pendingReleaseEvents.removeAll(keepingCapacity: false)
        pendingReleaseIdentities.removeAll(keepingCapacity: false)
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
                  !self.pending.isEmpty || !self.pendingReleaseEvents.isEmpty {
                let event: Event
                if !self.pending.isEmpty {
                    event = self.pending.removeFirst()
                } else {
                    event = self.pendingReleaseEvents.removeFirst()
                    if let identity = event.releaseIdentity {
                        self.pendingReleaseIdentities.remove(identity)
                    }
                }
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
            if (!pending.isEmpty || !pendingReleaseEvents.isEmpty), !Task.isCancelled {
                startWorkerIfNeeded()
            }
        }
    }

    /// If an unexpected input source exhausts the bounded release reserve,
    /// stop the child explicitly instead of dropping a release and leaving a
    /// key or mouse button latched. The reset task is owned by this queue and
    /// is canceled together with the queue lifecycle.
    private func beginFailClosedForOverflow() {
        guard !didFailClosedForOverflow else { return }
        didFailClosedForOverflow = true
        pending.removeAll(keepingCapacity: false)
        pendingReleaseEvents.removeAll(keepingCapacity: false)
        pendingReleaseIdentities.removeAll(keepingCapacity: false)
        worker?.cancel()
        worker = nil
        workerGeneration = nil
        guard overflowResetTask == nil else { return }
        let session = self.session
        overflowResetTask = Task { @MainActor [weak self, session] in
            _ = await session.stopAndWait()
            guard let self else { return }
            self.overflowResetTask = nil
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
