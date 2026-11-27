import Foundation

extension TerminalPasteboardTransactionLane {
    static let defaultMaximumQueuedOperations = 32
    static let defaultMaximumQueuedWriteBytes = 4 * 1_048_576

    enum MutationCondition: Sendable {
        case changeCount(Int)
    }

    struct Mutation: Sendable {
        let contents: [TerminalPasteboardItemSnapshot]
        let condition: MutationCondition?
        let capturesPreviousContents: Bool
    }

    enum Entry {
        case read(TerminalPasteboardReadLease)
        case mutation(
            id: UInt64,
            mutation: Mutation,
            lease: TerminalPasteboardMutationLease?,
            retainedBytes: Int,
            coalescible: Bool,
            isRestoration: Bool
        )

        var id: UInt64 {
            switch self {
            case .read(let lease):
                return lease.id
            case .mutation(let id, _, _, _, _, _):
                return id
            }
        }

        var retainedBytes: Int {
            guard case .mutation(
                _, _, _, let retainedBytes, _, _
            ) = self else {
                return 0
            }
            return retainedBytes
        }

        var isCoalescibleMutation: Bool {
            guard case .mutation(_, _, nil, _, true, false) = self else {
                return false
            }
            return true
        }

        var isRestoration: Bool {
            guard case .mutation(_, _, _, _, _, true) = self else {
                return false
            }
            return true
        }
    }

    struct ActiveMutation {
        let id: UInt64
        var isApplying = true
        var finishRequested = false
        var captureTask: Task<Void, Never>? = nil
    }

    struct LaneState {
        var nextID: UInt64 = 0
        var activeReadID: UInt64?
        var activeMutation: ActiveMutation?
        var entries: [Entry] = []
        var retainedMutationBytes = 0
        var restorationOperationCount = 0
    }

    enum DrainAction {
        case beginRead(TerminalPasteboardReadLease)
        case performMutation(
            id: UInt64,
            mutation: Mutation,
            lease: TerminalPasteboardMutationLease?,
            isRestoration: Bool
        )
    }

    enum MutationAdmission {
        case admitted(shouldDrain: Bool)
        case rejected
    }
}
