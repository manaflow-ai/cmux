internal import Darwin
internal import CmuxFoundation

/// Owns a duplicated descriptor that can interrupt one socket operation.
///
/// The atomics transfer exclusive ownership of the duplicate to either the
/// trigger or retirement path. The worker retains the original descriptor, so
/// an interrupt can never target a closed descriptor that the process reused.
final class PersistentSocketInterruptionSignal: Sendable {
    private static let noSocket = UInt64.max
    private static let triggered = UInt64.max - 1

    private let state = AtomicUInt64Value(noSocket)

    var isTriggered: Bool {
        state.loadRelaxed() == Self.triggered
    }

    deinit {
        retire()
    }

    func install(socket: Int32) -> Bool {
        let duplicate = Darwin.dup(socket)
        guard duplicate >= 0 else { return false }
        let descriptorFlags = Darwin.fcntl(duplicate, F_GETFD, 0)
        guard
            descriptorFlags >= 0,
            Darwin.fcntl(
                duplicate,
                F_SETFD,
                descriptorFlags | FD_CLOEXEC
            ) == 0
        else {
            Darwin.close(duplicate)
            return false
        }

        while true {
            let current = state.loadRelaxed()
            if current == Self.triggered {
                Darwin.close(duplicate)
                return false
            }
            if socketDescriptor(from: current) != nil {
                Darwin.close(duplicate)
                return true
            }
            guard current == Self.noSocket else {
                Darwin.close(duplicate)
                return false
            }
            if state.compareExchangeAcquiringAndReleasing(
                expected: Self.noSocket,
                desired: UInt64(duplicate)
            ) {
                return true
            }
        }
    }

    func trigger() {
        let stored = state.exchangeAcquiringAndReleasing(Self.triggered)
        guard let socket = socketDescriptor(from: stored) else { return }
        Darwin.shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
    }

    func retire() {
        let stored = state.exchangeAcquiringAndReleasing(
            Self.noSocket
        )
        if let socket = socketDescriptor(from: stored) {
            Darwin.close(socket)
        }
    }

    private func socketDescriptor(from stored: UInt64) -> Int32? {
        guard stored <= UInt64(Int32.max) else { return nil }
        return Int32(stored)
    }
}
