internal import CmuxMobileSSH
import Foundation

/// Keeps a cmux-tui topology subscription alive across transient control
/// transport failures.
///
/// The owner supplies the control type and its transport operations so the
/// reconnect lifecycle can be exercised without an SSH connection. A control
/// is replaced only after the old one is detached, and every replacement gets
/// a new generation. The generation lets the provider discard events and list
/// results that belong to a superseded control.
@MainActor
final class MobileSSHCmuxTUITopologyReconnect<Control: AnyObject & Sendable> {
    typealias Open = () async throws -> Control
    typealias Subscribe = (Control) async throws -> AsyncStream<CmuxTUIControlEvent>
    typealias Close = (Control) async -> Void
    typealias TransportIsOpen = () -> Bool
    typealias Sleep = (Duration) async throws -> Void

    /// The first retry delay after a topology control disconnects.
    nonisolated static var initialBackoff: Duration { .seconds(1) }
    /// The maximum retry delay while the owning SSH transport remains open.
    nonisolated static var maximumBackoff: Duration { .seconds(30) }
    /// A dead owner must eventually be allowed to fall out of discovery. The
    /// retry window covers the normal transient case while keeping a cached
    /// provider from blocking workspace listing forever.
    nonisolated static var maximumRecoveryAttempts: Int { 3 }

    /// Returns the capped delay for a zero-based reconnect attempt.
    nonisolated static func backoff(forAttempt attempt: Int) -> Duration {
        let shift = min(max(attempt, 0), 5)
        return min(Self.initialBackoff * (1 << shift), Self.maximumBackoff)
    }

    private let open: Open
    private let subscribe: Subscribe
    private let close: Close
    private let transportIsOpen: TransportIsOpen
    private let sleep: Sleep
    private let onEvent: @MainActor (CmuxTUIControlEvent, UInt64) -> Void
    private let onTransportGap: @MainActor (UInt64) -> Void
    private let onControlConnected: @MainActor (UInt64, Bool) -> Void
    private var watchTask: Task<Void, Never>?
    private var openingTask: Task<Control, Error>?
    private var recoveryTask: Task<Void, Never>?
    private var stopped = false
    private var postOpenSubscriptionFailures = 0

    /// The currently owned control, if the session is connected.
    private(set) var control: Control?
    /// Monotonically increasing identity for the current control lifecycle.
    private(set) var generation: UInt64 = 0

    init(
        open: @escaping Open,
        subscribe: @escaping Subscribe,
        close: @escaping Close,
        transportIsOpen: @escaping TransportIsOpen,
        sleep: @escaping Sleep,
        onEvent: @escaping @MainActor (CmuxTUIControlEvent, UInt64) -> Void,
        onTransportGap: @escaping @MainActor (UInt64) -> Void,
        onControlConnected: @escaping @MainActor (UInt64, Bool) -> Void
    ) {
        self.open = open
        self.subscribe = subscribe
        self.close = close
        self.transportIsOpen = transportIsOpen
        self.sleep = sleep
        self.onEvent = onEvent
        self.onTransportGap = onTransportGap
        self.onControlConnected = onControlConnected
    }

    /// Connects once, or waits for the in-flight connection attempt.
    func connect() async throws -> Control {
        guard !stopped else { throw CancellationError() }
        if let control { return control }
        if let recoveryTask {
            await recoveryTask.value
            guard !stopped else { throw CancellationError() }
            guard let control else { throw CmuxTUIError.closed }
            return control
        }
        return try await connectFresh()
    }

    private func connectFresh() async throws -> Control {
        guard !stopped else { throw CancellationError() }
        let task: Task<Control, Error>
        if let openingTask {
            task = openingTask
        } else {
            let newTask = Task { @MainActor [open] in
                try await open()
            }
            openingTask = newTask
            task = newTask
        }
        do {
            let candidate = try await task.value
            guard !stopped else {
                await close(candidate)
                throw CancellationError()
            }
            if let control {
                if control !== candidate { await close(candidate) }
                if openingTask != nil { openingTask = nil }
                return control
            }
            install(candidate)
            if openingTask != nil { openingTask = nil }
            return candidate
        } catch {
            if openingTask != nil { openingTask = nil }
            throw error
        }
    }

    /// Stops observation and closes the one control owned by this provider.
    func close() async {
        stopped = true
        watchTask?.cancel()
        watchTask = nil
        openingTask?.cancel()
        openingTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        let control = control
        self.control = nil
        if let control { await close(control) }
    }

    /// Replaces a control after a command failed, preserving one owner and
    /// using the same bounded retry policy as an event-driven disconnect.
    func reconnectAfterOperationFailure() async {
        if let recoveryTask {
            await recoveryTask.value
            return
        }
        guard let control else { return }
        watchTask?.cancel()
        await recover(from: control, generation: generation)
    }

    private func install(_ control: Control) {
        self.control = control
        generation &+= 1
        startWatching(control: control, generation: generation)
        onControlConnected(generation, generation > 1)
    }

    private func startWatching(control: Control, generation: UInt64) {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            await self?.watch(control: control, generation: generation)
        }
    }

    private func watch(control: Control, generation: UInt64) async {
        while !Task.isCancelled {
            guard isCurrent(control: control, generation: generation) else { return }
            do {
                let events = try await subscribe(control)
                var overflowed = false
                for await event in events {
                    guard !Task.isCancelled, isCurrent(control: control, generation: generation) else { return }
                    if event != .disconnected {
                        postOpenSubscriptionFailures = 0
                    }
                    onEvent(event, generation)
                    if event == .overflow { overflowed = true }
                    if event == .disconnected {
                        await recover(from: control, generation: generation)
                        return
                    }
                }
                if overflowed {
                    // The control remains valid; the next subscription starts
                    // at a fresh server snapshot after the overflow relist.
                    continue
                }
                postOpenSubscriptionFailures += 1
                await recover(from: control, generation: generation)
                return
            } catch is CancellationError {
                return
            } catch {
                postOpenSubscriptionFailures += 1
                await recover(from: control, generation: generation)
                return
            }
        }
    }

    private func recover(from control: Control, generation: UInt64) async {
        guard !Task.isCancelled, !stopped, isCurrent(control: control, generation: generation) else { return }
        if let recoveryTask {
            await recoveryTask.value
            if !Task.isCancelled, !stopped, isCurrent(control: control, generation: generation) {
                await recover(from: control, generation: generation)
            }
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRecovery(from: control, generation: generation)
            self.recoveryTask = nil
        }
        recoveryTask = task
        await task.value
    }

    private func runRecovery(from control: Control, generation: UInt64) async {
        guard !Task.isCancelled, !stopped, isCurrent(control: control, generation: generation) else { return }
        self.control = nil
        self.generation &+= 1
        watchTask = nil
        await close(control)
        onTransportGap(self.generation)
        guard transportIsOpen() else { return }

        var attempt = postOpenSubscriptionFailures
        guard attempt < Self.maximumRecoveryAttempts else { return }
        if attempt > 0 {
            do {
                try await sleep(Self.backoff(forAttempt: attempt - 1))
            } catch {
                return
            }
        }
        while !Task.isCancelled, !stopped, transportIsOpen(), attempt < Self.maximumRecoveryAttempts {
            do {
                _ = try await connectFresh()
                return
            } catch is CancellationError {
                return
            } catch {
                attempt += 1
                guard attempt < Self.maximumRecoveryAttempts else { return }
                do {
                    try await sleep(Self.backoff(forAttempt: attempt - 1))
                } catch {
                    return
                }
            }
        }
    }

    private func isCurrent(control: Control, generation: UInt64) -> Bool {
        self.control === control && self.generation == generation
    }
}
