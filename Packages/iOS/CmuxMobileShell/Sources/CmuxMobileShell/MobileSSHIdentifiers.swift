import Foundation

/// An identifier string read as an SSH computer's id.
///
/// SSH hosts ride the shell's ordinary per-computer stores (like the
/// demonstration computer), so every id they mint must be distinguishable
/// from a Mac's without consulting live session state:
///
/// - computer (`macDeviceID`): `cmux-ssh-<host uuid>`
/// - workspace row / terminal surface: `cmux-ssh-<host uuid>~<local id>`
///
/// The `~` separator never appears in a UUID, so the host id parses back
/// unambiguously.
struct MobileSSHIdentifier: Hashable, Sendable {
    static let prefix = "cmux-ssh-"
    private static let separator: Character = "~"

    /// The identifier string as the shell's stores carry it.
    let rawValue: String

    /// Reads any identifier; the accessors report whether it is an SSH one.
    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// The computer (`macDeviceID`) id for an SSH host.
    init(computerOf host: UUID) {
        self.init(Self.prefix + host.uuidString.lowercased())
    }

    /// A workspace, terminal, or browser id scoped to an SSH host.
    init(host: UUID, local: String) {
        self.init(MobileSSHIdentifier(computerOf: host).rawValue + String(Self.separator) + local)
    }

    /// Whether this identifier belongs to any SSH computer.
    var isSSH: Bool {
        rawValue.hasPrefix(Self.prefix)
    }

    /// Whether this is a well-formed workspace or surface id
    /// (`cmux-ssh-<host uuid>~<local id>`). Aggregated row ids that merely
    /// start with the prefix are not.
    var isScoped: Bool {
        hostID != nil && localID != nil
    }

    /// The host that owns this computer, workspace, or surface id.
    var hostID: UUID? {
        guard isSSH else { return nil }
        let rest = rawValue.dropFirst(Self.prefix.count)
        let hostPart = rest.split(separator: Self.separator, maxSplits: 1).first.map(String.init) ?? String(rest)
        return UUID(uuidString: hostPart)
    }

    /// The host-local part of a scoped workspace or surface id.
    var localID: String? {
        guard isSSH, let index = rawValue.firstIndex(of: Self.separator) else { return nil }
        return String(rawValue[rawValue.index(after: index)...])
    }
}

/// What one SSH workspace row is (PRD D31). A host serves every kind at
/// once over one connection; each row is exactly one kind's top-level
/// primitive, and everything below it lives inside the workspace.
public enum MobileSSHWorkspaceKind: String, CaseIterable, Sendable, Hashable {
    /// A cmux-tui workspace (screens → panes → tabs), from any cmux-tui
    /// session on the server.
    case cmuxTUI
    /// A tmux session (windows → panes).
    case tmux
    /// One login shell opened from this phone. Nothing nested.
    case shell
}

/// The host-local part of an SSH workspace, terminal, or browser id, with
/// its kind encoded so ids from different kinds never collide (PRD D31):
///
/// - cmux-tui: `tui:<session>/<id>` (workspace key, terminal or browser
///   resource id). cmux-tui session names never contain `/`, so the first
///   `/` splits.
/// - tmux: `tmux:<id>` (session name, or `<session>/%<pane>`).
/// - shell: `shell:<n>` (the workspace and its one terminal share it).
///
/// Scoped ids stay `cmux-ssh-<host>~<local>` (``MobileSSHIdentifier``).
enum MobileSSHLocalID: Hashable, Sendable {
    case cmuxTUI(session: String, id: String)
    case tmux(String)
    case shell(String)

    var kind: MobileSSHWorkspaceKind {
        switch self {
        case .cmuxTUI: .cmuxTUI
        case .tmux: .tmux
        case .shell: .shell
        }
    }

    /// The id the kind's provider knows.
    var providerID: String {
        switch self {
        case .cmuxTUI(_, let id), .tmux(let id), .shell(let id): id
        }
    }

    var rawValue: String {
        switch self {
        case .cmuxTUI(let session, let id): "tui:\(session)/\(id)"
        case .tmux(let id): "tmux:\(id)"
        case .shell(let id): "shell:\(id)"
        }
    }

    init?(rawValue: String) {
        if let rest = rawValue.dropPrefix("tui:") {
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let session = String(rest[..<slash])
            let id = String(rest[rest.index(after: slash)...])
            guard !session.isEmpty, !id.isEmpty else { return nil }
            self = .cmuxTUI(session: session, id: id)
        } else if let rest = rawValue.dropPrefix("tmux:"), !rest.isEmpty {
            self = .tmux(String(rest))
        } else if let rest = rawValue.dropPrefix("shell:"), !rest.isEmpty {
            self = .shell(String(rest))
        } else {
            return nil
        }
    }

    /// Parses the local part of a scoped workspace or surface id.
    init?(scopedID: String) {
        guard let local = MobileSSHIdentifier(scopedID).localID else { return nil }
        self.init(rawValue: local)
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
