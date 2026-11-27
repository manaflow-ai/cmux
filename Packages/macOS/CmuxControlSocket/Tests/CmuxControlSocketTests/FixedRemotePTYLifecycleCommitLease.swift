@testable import CmuxControlSocket
import os

final class FixedRemotePTYLifecycleCommitLease:
    ControlRemotePTYLifecycleCommitLease,
    Sendable
{
    private enum DeliveryState {
        case available
        case inFlight
        case completed
    }

    let isCurrent: Bool
    private let deliveryState = OSAllocatedUnfairLock(initialState: DeliveryState.available)

    init(isCurrent: Bool) {
        self.isCurrent = isCurrent
    }

    func beginReadinessDelivery() -> ControlRemotePTYReadinessDeliveryAdmission {
        guard isCurrent else { return .stale }
        return deliveryState.withLock { state in
            switch state {
            case .available:
                state = .inFlight
                return .acquired
            case .inFlight:
                return .inFlight
            case .completed:
                return .alreadyCompleted
            }
        }
    }

    func finishReadinessDelivery(succeeded: Bool) {
        deliveryState.withLock { state in
            guard state == .inFlight else { return }
            state = succeeded ? .completed : .available
        }
    }

    @MainActor
    func commitIfCurrent(
        _ operation: @MainActor @Sendable () -> Bool
    ) -> Bool {
        guard isCurrent else { return false }
        return operation()
    }
}
