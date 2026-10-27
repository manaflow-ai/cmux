import Foundation

/// The ops and streams of one page namespace, each with what it can do (p13-webui.md 3.B, task 087).
/// A descriptor that declares a namespace's table admits only the names in it (``PageDescriptor/admits(_:)``),
/// so the router refuses an op the table does not list before any provider sees it, and
/// ``PageCapability`` reads the same table to put the page in a process group. A namespace with no
/// table is undeclared: its page may reach anything under it, so it shares a renderer with no other
/// page. This is Chrome's per-interface rule for WebUI bindings: a renderer gets only the Mojo
/// interfaces its WebUI controller binds (`content/public/browser/web_ui_controller_interface_binder.h`),
/// and the process lock follows what those can reach.
public nonisolated struct PageOpTable: Sendable, Hashable {
    /// What one op can do. Ordered: a name declared twice keeps the stronger kind.
    public nonisolated enum Kind: Int, Sendable, Hashable, Comparable, CustomStringConvertible {
        /// Reads app data, or changes only what this page shows (its filter, selection, scroll).
        case read
        /// Changes app state or acts for the person: writes a setting, opens a tab or a link,
        /// stops a session.
        case act
        /// Acts on the host as the person: a shell, git writes, a file save, a harness, a transport.
        case hostPower

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        public var description: String {
            switch self {
            case .read: "read"
            case .act: "act"
            case .hostPower: "host power"
            }
        }
    }

    /// Names, relative to the namespace, that act on the host whatever a table declares: `shell.run`,
    /// `git.push`, `save`. A name ending in `.` covers every name under it. A table cannot declare
    /// one of these, or one of ``hostPowerOps``, weaker than ``Kind/hostPower``.
    public static let hostPowerNames: [String] = [
        "shell.", "git.push", "git.commit", "git.worktree.", "harness.", "transport.", "save", "pane.saveFile",
    ]
    /// Full op names that act on the host under a namespace whose other ops do not: the Chief
    /// editor's harness center registers a person-brought `{command, args}` (`add`) and runs a real
    /// turn on it (`doctor`) (`ChiefBackendPageRoute`). Matched on the full name, so `add` elsewhere
    /// stays what its table says; an undeclared namespace that covers one still reports it.
    public static let hostPowerOps: Set<String> = ["cmux.chief.backend.add", "cmux.chief.backend.doctor"]

    /// The op prefix (`cmux.files.`), one of the descriptor's namespaces.
    public let namespace: String
    /// Every full op and stream name the namespace answers, with its kind.
    public let kinds: [String: Kind]

    /// - Parameters:
    ///   - namespace: The descriptor namespace (`cmux.files.`).
    ///   - read, act, hostPower: Op and stream names relative to `namespace` (`list`, `open`).
    public init(namespace: String, read: Set<String> = [], act: Set<String> = [], hostPower: Set<String> = []) {
        self.namespace = namespace
        var kinds: [String: Kind] = [:]
        let groups: [(names: Set<String>, kind: Kind)] = [(read, .read), (act, .act), (hostPower, .hostPower)]
        for (names, kind) in groups {
            for name in names {
                let op = namespace + name
                let declared = Self.isHostPower(name) || Self.hostPowerOps.contains(op) ? Kind.hostPower : kind
                kinds[op] = max(kinds[op] ?? declared, declared)
            }
        }
        self.kinds = kinds
    }

    /// The kind of `op`, or nil when the table does not list it.
    public func kind(of op: String) -> Kind? { kinds[op] }

    /// The full names of the given kind, sorted.
    public func ops(_ kind: Kind) -> [String] { kinds.filter { $0.value == kind }.keys.sorted() }

    /// Whether `name` (relative to the namespace) matches ``hostPowerNames``.
    public static func isHostPower(_ name: String) -> Bool {
        hostPowerNames.contains { $0.hasSuffix(".") ? name.hasPrefix($0) : name == $0 }
    }
}
