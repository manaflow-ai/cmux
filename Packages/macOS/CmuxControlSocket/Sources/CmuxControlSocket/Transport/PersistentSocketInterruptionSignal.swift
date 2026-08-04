internal import CmuxFoundation
internal import Darwin

private let noInterruptionSocket = UInt32.max
private let interruptionInProgress = UInt32.max - 1
private let interruptionCompleted = UInt32.max - 2

/// Owns a generation-scoped duplicate that can interrupt one socket operation.
///
/// Atomic generation changes prevent an interrupt that already claimed an old
/// duplicate from reaching a later persistent-socket operation. The trigger
/// owns that duplicate until its synchronous shutdown finishes; retirement
/// reports the claim so the worker closes the old persistent connection.
final class PersistentSocketInterruptionSignal: Sendable {
    private let state = AtomicUInt64Value(
        packedInterruptionState(
            generation: 0,
            status: noInterruptionSocket
        )
    )
    private let duplicateSocket: @Sendable (Int32) -> Int32
    private let interruptSocket: @Sendable (Int32) -> Void

    init(
        duplicateSocket: @escaping @Sendable (Int32) -> Int32 = {
            Darwin.fcntl($0, F_DUPFD_CLOEXEC, 0)
        },
        interruptSocket: @escaping @Sendable (Int32) -> Void = {
            Darwin.shutdown($0, SHUT_RDWR)
            Darwin.close($0)
        }
    ) {
        self.duplicateSocket = duplicateSocket
        self.interruptSocket = interruptSocket
    }

    deinit {
        retireCurrentGeneration()
    }

    func begin() -> UInt32 {
        while true {
            let current = state.loadRelaxed()
            let generation = interruptionGeneration(from: current) &+ 1
            let desired = packedInterruptionState(
                generation: generation,
                status: noInterruptionSocket
            )
            guard state.compareExchangeAcquiringAndReleasing(
                expected: current,
                desired: desired
            ) else {
                continue
            }
            if let socket = interruptionSocketDescriptor(from: current) {
                Darwin.close(socket)
            }
            return generation
        }
    }

    func install(socket: Int32, generation: UInt32) -> Bool {
        let duplicate = duplicateSocket(socket)
        guard duplicate >= 0 else { return false }
        let desired = packedInterruptionState(
            generation: generation,
            status: UInt32(duplicate)
        )
        while true {
            let current = state.loadRelaxed()
            guard interruptionGeneration(from: current) == generation else {
                Darwin.close(duplicate)
                return false
            }
            let status = interruptionStatus(from: current)
            if status == interruptionInProgress ||
                status == interruptionCompleted
            {
                Darwin.close(duplicate)
                return false
            }
            if let installedSocket = interruptionSocketDescriptor(from: current) {
                guard state.compareExchangeAcquiringAndReleasing(
                    expected: current,
                    desired: desired
                ) else {
                    continue
                }
                Darwin.close(installedSocket)
                return true
            }
            guard status == noInterruptionSocket else {
                Darwin.close(duplicate)
                return false
            }
            if state.compareExchangeAcquiringAndReleasing(
                expected: current,
                desired: desired
            ) {
                return true
            }
        }
    }

    func trigger(generation: UInt32) {
        while true {
            let current = state.loadRelaxed()
            guard interruptionGeneration(from: current) == generation else {
                return
            }
            let status = interruptionStatus(from: current)
            if status == interruptionInProgress ||
                status == interruptionCompleted
            {
                return
            }
            if status == noInterruptionSocket {
                let desired = packedInterruptionState(
                    generation: generation,
                    status: interruptionCompleted
                )
                if state.compareExchangeAcquiringAndReleasing(
                    expected: current,
                    desired: desired
                ) {
                    return
                }
                continue
            }
            guard let socket = interruptionSocketDescriptor(from: current) else {
                return
            }
            let interrupting = packedInterruptionState(
                generation: generation,
                status: interruptionInProgress
            )
            guard state.compareExchangeAcquiringAndReleasing(
                expected: current,
                desired: interrupting
            ) else {
                continue
            }
            interruptSocket(socket)
            _ = state.compareExchangeAcquiringAndReleasing(
                expected: interrupting,
                desired: packedInterruptionState(
                    generation: generation,
                    status: interruptionCompleted
                )
            )
            return
        }
    }

    func triggerCurrentGeneration() {
        let current = state.loadRelaxed()
        trigger(generation: interruptionGeneration(from: current))
    }

    func isTriggered(generation: UInt32) -> Bool {
        let current = state.loadRelaxed()
        guard interruptionGeneration(from: current) == generation else {
            return false
        }
        let status = interruptionStatus(from: current)
        return status == interruptionInProgress ||
            status == interruptionCompleted
    }

    /// Retires one generation and reports whether its interrupt won ownership.
    ///
    /// A `true` result requires the worker to close its original persistent
    /// socket before starting another operation. The trigger may still hold a
    /// duplicate, but its old generation can no longer mutate this signal.
    func retire(generation: UInt32) -> Bool {
        while true {
            let current = state.loadRelaxed()
            guard interruptionGeneration(from: current) == generation else {
                return false
            }
            let status = interruptionStatus(from: current)
            let desired = packedInterruptionState(
                generation: generation &+ 1,
                status: noInterruptionSocket
            )
            guard state.compareExchangeAcquiringAndReleasing(
                expected: current,
                desired: desired
            ) else {
                continue
            }
            if let socket = interruptionSocketDescriptor(from: current) {
                Darwin.close(socket)
            }
            return status == interruptionInProgress ||
                status == interruptionCompleted
        }
    }

    func retireCurrentGeneration() {
        let current = state.loadRelaxed()
        _ = retire(generation: interruptionGeneration(from: current))
    }
}

private func packedInterruptionState(
    generation: UInt32,
    status: UInt32
) -> UInt64 {
    UInt64(generation) << 32 | UInt64(status)
}

private func interruptionGeneration(from state: UInt64) -> UInt32 {
    UInt32(truncatingIfNeeded: state >> 32)
}

private func interruptionStatus(from state: UInt64) -> UInt32 {
    UInt32(truncatingIfNeeded: state)
}

private func interruptionSocketDescriptor(from state: UInt64) -> Int32? {
    let status = interruptionStatus(from: state)
    guard status <= UInt32(Int32.max) else { return nil }
    return Int32(status)
}
