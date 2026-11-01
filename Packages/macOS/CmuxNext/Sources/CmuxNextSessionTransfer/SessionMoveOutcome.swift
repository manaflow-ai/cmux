public import CmuxNextSettings
import Foundation

/// What Move Sessions from Another cmux Build… did (cx-yxmkh), as its toast
/// says it: that the sessions moved, then each session or build that did not
/// and why.
public nonisolated struct SessionMoveOutcome: Equatable {
    /// How many sessions moved.
    public var moved = 0
    /// One sentence per session or build that did not move.
    public var failures: [String] = []

    /// An outcome with nothing recorded yet.
    public init() {}

    /// One `SessionTransferService.pull` result; `titles` names its sessions.
    /// - Parameters:
    ///   - result: The pull's `moved` and `failed` lists.
    ///   - titles: Session titles by id in the pulled build.
    public mutating func record(_ result: JSONValue, titles: [String: String]) {
        moved += result["moved"]?.arrayValue?.count ?? 0
        for failure in result["failed"]?.arrayValue ?? [] {
            let id = failure["surface"]?.stringValue ?? ""
            failures.append(Self.couldNotMove(titles[id] ?? id, failure["error"]?.stringValue ?? Self.failed))
        }
    }

    /// A pull from build `heading` that failed as a whole, for `reason` (the error's message).
    /// - Parameters:
    ///   - reason: Why the pull failed, as a sentence.
    ///   - heading: The build's heading.
    public mutating func record(failure reason: String, from heading: String) {
        failures.append(Self.couldNotMove(from: heading, reason))
    }

    /// The toast's text.
    public var notice: String {
        guard moved > 0 || !failures.isEmpty else { return Self.nothingMoved }
        let moved = moved == 0 ? [] : [failures.isEmpty ? Self.movedAll : Self.movedOthers]
        return (moved + failures).joined(separator: " ")
    }

    /// Localized text: none.
    public static var none: String {
        String(localized: "sessionMove.toast.none", defaultValue: "No other cmux build has sessions to move.", bundle: .module)
    }
    /// Localized text: movedAll.
    public static var movedAll: String {
        String(localized: "sessionMove.toast.moved", defaultValue: "The sessions moved here.", bundle: .module)
    }
    /// Localized text: movedOthers.
    public static var movedOthers: String {
        String(localized: "sessionMove.toast.movedOthers", defaultValue: "The other sessions moved here.", bundle: .module)
    }
    /// Localized text: nothingMoved.
    public static var nothingMoved: String {
        String(localized: "sessionMove.toast.nothingMoved", defaultValue: "No sessions moved.", bundle: .module)
    }
    /// Localized text: failed.
    public static var failed: String {
        String(localized: "sessionTransfer.error.failed", defaultValue: "Could not move sessions from the other cmux build.", bundle: .module)
    }
    /// Localized text: a session or build that did not move, and why.
    public static func couldNotMove(_ title: String, _ reason: String) -> String {
        String(localized: "sessionMove.toast.failedSession", defaultValue: "Couldn’t move “\(title)”: \(reason)", bundle: .module)
    }
    /// Localized text: a session or build that did not move, and why.
    public static func couldNotMove(from build: String, _ reason: String) -> String {
        String(localized: "sessionMove.toast.failedBuild", defaultValue: "Couldn’t move sessions from \(build): \(reason)", bundle: .module)
    }
}
