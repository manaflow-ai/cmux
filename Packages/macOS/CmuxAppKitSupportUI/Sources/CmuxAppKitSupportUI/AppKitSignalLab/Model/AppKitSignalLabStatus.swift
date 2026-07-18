import Foundation

enum AppKitSignalLabStatus: String, CaseIterable, Equatable {
    case queued
    case running
    case review
    case blocked
    case complete

    var title: String {
        switch self {
        case .queued:
            String(localized: "debug.signalLab.status.queued", defaultValue: "Queued")
        case .running:
            String(localized: "debug.signalLab.status.running", defaultValue: "Running")
        case .review:
            String(localized: "debug.signalLab.status.review", defaultValue: "Review")
        case .blocked:
            String(localized: "debug.signalLab.status.blocked", defaultValue: "Blocked")
        case .complete:
            String(localized: "debug.signalLab.status.complete", defaultValue: "Complete")
        }
    }

    var systemImageName: String {
        switch self {
        case .queued: "clock"
        case .running: "bolt.fill"
        case .review: "eye.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .complete: "checkmark.circle.fill"
        }
    }
}
