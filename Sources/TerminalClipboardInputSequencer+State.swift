import Foundation

extension TerminalClipboardInputSequencer {
    typealias ReservedOverflowHandler = @MainActor @Sendable () -> Void

    struct ReservedAdmission: Sendable {
        let epoch: UInt64
        let order: UInt64
        let overflowHandler: ReservedOverflowHandler
    }

    enum OverflowAction {
        case active(() -> Void)
        case reserved(ReservedOverflowHandler)

        @MainActor
        func perform() {
            switch self {
            case .active(let handler):
                handler()
            case .reserved(let handler):
                handler()
            }
        }
    }

    struct OrderedOverflowHandler {
        let order: UInt64
        let action: OverflowAction
    }

    struct ReservedAdmissionState: Sendable {
        var nextOrder: UInt64 = 0
        var admissionsByID: [RequestID: ReservedAdmission] = [:]
        var overflowCancellationDepthByEpoch: [UInt64: Int] = [:]
    }

    struct BufferedEvent {
        let event: Event
        let discardWhenFull: Bool
        let estimatedCost: Int
    }

    struct EpochBuffer {
        var events: [BufferedEvent] = []
        var nextEventIndex = 0
        var pendingCost = 0

        var pendingCount: Int {
            events.count - nextEventIndex
        }
    }

    struct ActiveRequest {
        let epoch: UInt64
        let defersInput: Bool
        let reservationOrder: UInt64?
        let onOverflow: () -> Void
        var readyCompletion: (() -> Void)?
    }
}
