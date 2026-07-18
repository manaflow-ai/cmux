import Foundation

enum AppKitSignalLabFilter: Equatable {
    case all
    case active
    case blocked
    case complete

    var title: String {
        switch self {
        case .all:
            String(localized: "debug.signalLab.filter.all", defaultValue: "All work")
        case .active:
            String(localized: "debug.signalLab.filter.active", defaultValue: "Active")
        case .blocked:
            String(localized: "debug.signalLab.filter.blocked", defaultValue: "Blocked")
        case .complete:
            String(localized: "debug.signalLab.filter.complete", defaultValue: "Complete")
        }
    }

    func includes(_ status: AppKitSignalLabStatus) -> Bool {
        switch self {
        case .all:
            true
        case .active:
            status == .running || status == .review
        case .blocked:
            status == .blocked
        case .complete:
            status == .complete
        }
    }
}
