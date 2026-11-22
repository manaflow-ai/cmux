public import Foundation

/// Where a Chief runs now (chief-migration-DESIGN.md 7), as its home's `state/moved.json` says: no
/// marker is This Mac; a move writes the target it went to (`local:<dir>`, `ssh:<host>:<dir>`,
/// `cloud:<api>/<agent id>`), and a rollback's retire on the far side writes `<host>:<dir>`.
///
/// ```swift
/// ChiefLocation(movedTo: "ssh:me@cmux-mini:~/.cmux/chief/default") // .host("cmux-mini")
/// ```
public nonisolated enum ChiefLocation: Equatable, Sendable {
    /// No marker (or one the engine would not read either, so its host starts here).
    case thisMac
    /// The account's hosted Chief in cmux Cloud.
    case cloud
    /// Another machine, by its host name (no `user@`, no home folder).
    case host(String)

    /// The location a `moved.json` `to` value names; nil or empty is This Mac.
    ///
    /// - Parameter movedTo: The marker's `to` field.
    public init(movedTo: String?) {
        guard let to = movedTo?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty else {
            self = .thisMac
            return
        }
        if to.hasPrefix("local:") {
            self = .thisMac
        } else if to == "cloud" || to.hasPrefix("cloud:") {
            self = .cloud
        } else if to.hasPrefix("ssh:") {
            self = Self.host(of: String(to.dropFirst("ssh:".count)))
        } else {
            self = Self.host(of: to)
        }
    }

    /// The location a whole `moved.json` names; no file, or one that is not the engine's marker, is This Mac.
    ///
    /// - Parameter movedJSON: The file's bytes, nil when there is none.
    public init(movedJSON: Data?) {
        self = ChiefWhereabouts(movedJSON: movedJSON).location
    }

    /// `host[:dir]` or `user@host[:dir]` as a host name.
    private static func host(of destination: String) -> ChiefLocation {
        let name = Self.hostName(destination)
        return name.isEmpty ? .thisMac : .host(name)
    }

    /// The host name in an SSH destination (`user@host`, `host:dir`), lowercased for matching.
    static func hostName(_ destination: String) -> String {
        let withoutDir = destination.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let host = withoutDir.split(separator: "@").last.map(String.init) ?? withoutDir
        return host.lowercased()
    }
}
