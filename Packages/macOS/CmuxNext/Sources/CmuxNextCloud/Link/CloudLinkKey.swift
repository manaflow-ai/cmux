import Foundation

/// The key of one Cloud machine's link, `cmux/cloud/<machine>`: the app id
/// and the link target, as `apps-terminal-link {app, target}` names it.
public struct CloudLinkKey: Hashable, Sendable, CustomStringConvertible {
    /// The Cloud app's id.
    public static let app = "cmux/cloud"
    public let machine: String

    public init(machine: String) {
        self.machine = machine
    }

    /// The key of an app link; nil for another app's link or no target.
    public init?(app: String, target: String) {
        guard app == Self.app, !target.isEmpty else { return nil }
        machine = target
    }

    public var description: String { "\(Self.app)/\(machine)" }
}

/// Who asked for a connect: the `apps-run` origin. A click is `user`; a
/// connect the app starts by itself (launch, machine resumed) is `script`.
public enum CloudLinkOrigin: String, Sendable {
    case user
    case script
}

/// A link's local socket, checked by ``CloudLinkSocketPolicy``.
public struct CloudLinkSocket: Equatable, Sendable {
    public let key: CloudLinkKey
    public let path: String
    /// The carrier generation; orders `cloud.link.changed` events. Nil when
    /// the source has none.
    public let generation: UInt64?
    /// This connect's answer said the signed-in caller owns the machine (`vm_kind: "owner"`, the
    /// classic attach answer's value; cmux-platform#89). Only for this connect, never saved.
    public let callerOwnsVM: Bool
    /// This connect's answer said the machine is a teammate's (`vm_kind: "team"`): a chat start
    /// there is refused as a teammate's machine, never sent. Grants nothing.
    public let callerIsTeammate: Bool

    public init(key: CloudLinkKey, path: String, generation: UInt64?, callerOwnsVM: Bool = false, callerIsTeammate: Bool = false) {
        self.key = key
        self.path = path
        self.generation = generation
        self.callerOwnsVM = callerOwnsVM
        self.callerIsTeammate = callerIsTeammate && !callerOwnsVM
    }
}
