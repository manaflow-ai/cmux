import Foundation

enum AppKitSignalLabFilter: Equatable {
    case all
    case active
    case blocked
    case complete

    var title: String {
        switch self {
        case .all:
            String(localized: "debug.signalLab.filter.all", defaultValue: "All todos")
        case .active:
            String(localized: "debug.signalLab.filter.active", defaultValue: "Open")
        case .blocked:
            String(localized: "debug.signalLab.filter.blocked", defaultValue: "Blocked")
        case .complete:
            String(localized: "debug.signalLab.filter.complete", defaultValue: "Done")
        }
    }

    func includes(_ status: AppKitSignalLabStatus) -> Bool {
        switch self {
        case .all:
            true
        case .active:
            status == .queued || status == .running || status == .review
        case .blocked:
            status == .blocked
        case .complete:
            status == .complete
        }
    }
}
