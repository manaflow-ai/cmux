import Foundation

/// Lifecycle of one provider-reported workload.
enum AgentWorkloadPhase: String, Codable, Sendable, Equatable {
    case queued
    case running
    case watching
    case waiting
    case completed
    case failed
    case cancelled
    case unknown

    var isActive: Bool {
        switch self {
        case .queued, .running, .watching, .waiting: true
        case .completed, .failed, .cancelled, .unknown: false
        }
    }
}
