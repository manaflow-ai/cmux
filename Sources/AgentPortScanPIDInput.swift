import Foundation

/// Source of agent process IDs for a queued port scan.
enum AgentPortScanPIDInput: Sendable, Equatable {
    case captured([UUID: Set<Int>])
    case refreshProvider

    func merging(_ newer: Self) -> Self {
        switch (self, newer) {
        case (.refreshProvider, _), (_, .refreshProvider):
            return .refreshProvider
        case (.captured(let current), .captured(let update)):
            return .captured(current.merging(update) { _, new in new })
        }
    }
}
