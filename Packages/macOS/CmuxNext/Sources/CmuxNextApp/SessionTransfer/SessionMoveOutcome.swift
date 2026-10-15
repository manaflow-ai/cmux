import Foundation

/// What Move Sessions from Another cmux Build… did (cx-yxmkh), as its toast
/// says it: that the sessions moved, then each session or build that did not
/// and why.
nonisolated struct SessionMoveOutcome: Equatable {
    var moved = 0
    var failures: [String] = []

    /// One `SessionTransferService.pull` result; `titles` names its sessions.
    mutating func record(_ result: TransferJSONValue, titles: [String: String]) {
        moved += result["moved"]?.arrayValue?.count ?? 0
        for failure in result["failed"]?.arrayValue ?? [] {
            let id = failure["surface"]?.stringValue ?? ""
            failures.append(Self.couldNotMove(titles[id] ?? id, failure["error"]?.stringValue ?? Self.failed))
        }
    }

    /// A pull from build `heading` that failed as a whole.
    mutating func record(_ error: Error, from heading: String) {
        failures.append(Self.couldNotMove(from: heading, SessionTransferService.message(for: error)))
    }

    var notice: String {
        guard moved > 0 || !failures.isEmpty else { return Self.nothingMoved }
        let moved = moved == 0 ? [] : [failures.isEmpty ? Self.movedAll : Self.movedOthers]
        return (moved + failures).joined(separator: " ")
    }

    static var none: String {
        String(localized: "sessionMove.toast.none", defaultValue: "No other cmux build has sessions to move.", bundle: .module)
    }
    static var movedAll: String {
        String(localized: "sessionMove.toast.moved", defaultValue: "The sessions moved here.", bundle: .module)
    }
    static var movedOthers: String {
        String(localized: "sessionMove.toast.movedOthers", defaultValue: "The other sessions moved here.", bundle: .module)
    }
    static var nothingMoved: String {
        String(localized: "sessionMove.toast.nothingMoved", defaultValue: "No sessions moved.", bundle: .module)
    }
    static var failed: String {
        String(localized: "sessionTransfer.error.failed", defaultValue: "Could not move sessions from the other cmux build.", bundle: .module)
    }
    static func couldNotMove(_ title: String, _ reason: String) -> String {
        String(localized: "sessionMove.toast.failedSession", defaultValue: "Couldn’t move “\(title)”: \(reason)", bundle: .module)
    }
    static func couldNotMove(from build: String, _ reason: String) -> String {
        String(localized: "sessionMove.toast.failedBuild", defaultValue: "Couldn’t move sessions from \(build): \(reason)", bundle: .module)
    }
}
