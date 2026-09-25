internal import CmuxMobileSSH
internal import CmuxMobileSupport
import Foundation

/// Whether one workspace kind can be created on a host, and why not.
public struct MobileSSHKindAvailability: Equatable, Sendable, Identifiable {
    public var kind: MobileSSHWorkspaceKind
    /// `nil` when the kind can be created.
    public var unavailableReason: String?
    /// cmux-tui only: the first workspace uploads cmux-tui first (PRD D10).
    public var needsInstall: Bool

    public var id: MobileSSHWorkspaceKind { kind }
    public var isAvailable: Bool { unavailableReason == nil }

    public init(kind: MobileSSHWorkspaceKind, unavailableReason: String? = nil, needsInstall: Bool = false) {
        self.kind = kind
        self.unavailableReason = unavailableReason
        self.needsInstall = needsInstall
    }

    /// Before the host is probed every kind is offered; creating one
    /// connects first and reports a real failure on the host.
    public static let unprobed: [MobileSSHKindAvailability] = MobileSSHWorkspaceKind.allCases.map {
        MobileSSHKindAvailability(kind: $0)
    }
}

/// Every workspace kind one SSH connection serves at once (PRD D31): the
/// phone's plain shells always, tmux sessions when tmux is installed, and
/// cmux-tui workspaces from every cmux-tui session on the server when
/// cmux-tui is installed (the phone's own session is created on the first
/// cmux-tui workspace, uploading cmux-tui if needed).
///
/// Every id leaving the registry is a kind-encoded ``MobileSSHLocalID``
/// raw value; every id entering it is parsed back and dispatched to its
/// kind's provider with the provider's own id.
@MainActor
final class MobileSSHHostProviders {
    private let connection: SSHConnection?
    private let idleCloseSeconds: Int?
    /// tmux (a ``MobileSSHTmuxProvider`` in the app); `nil` when tmux is
    /// not installed.
    private(set) var tmux: (any MobileSSHWorkspaceProvider)?
    private let plain: any MobileSSHWorkspaceProvider
    /// The installed cmux-tui binary, if any.
    private(set) var cmuxTUIBinary: String?
    /// `uname` of the server, for the installer and the unsupported reason.
    private let cmuxTUIProbe: CmuxTUIProbe?
    /// One provider per cmux-tui session, created on first use.
    private var cmuxTUI: [String: MobileSSHCmuxTUIProvider] = [:]
    var onTopologyChange: (@MainActor () -> Void)? {
        didSet { (tmux as? any MobileSSHTopologyReporting)?.onTopologyChange = onTopologyChange }
    }

    private init(
        connection: SSHConnection?,
        idleCloseSeconds: Int?,
        tmux: (any MobileSSHWorkspaceProvider)?,
        plain: any MobileSSHWorkspaceProvider,
        cmuxTUIBinary: String?,
        cmuxTUIProbe: CmuxTUIProbe?
    ) {
        self.connection = connection
        self.idleCloseSeconds = idleCloseSeconds
        self.tmux = tmux
        self.plain = plain
        self.cmuxTUIBinary = cmuxTUIBinary
        self.cmuxTUIProbe = cmuxTUIProbe
    }

    /// Probes the host once per connection: tmux, an installed cmux-tui, and
    /// the platform (for installing one). Probes never fail the connection.
    static func make(connection: SSHConnection, host: SSHHostRecord) async -> MobileSSHHostProviders {
        async let tmuxPath = MobileSSHTmuxProvider.probe(on: connection)
        async let binary = CmuxTUIRemote.locateBinary(on: connection)
        async let probe = try? CmuxTUIRemote().probe(on: connection)
        let tmux = await tmuxPath.map { MobileSSHTmuxProvider(connection: connection, tmuxPath: $0) }
        return await MobileSSHHostProviders(
            connection: connection,
            idleCloseSeconds: host.idleClose.seconds,
            tmux: tmux,
            plain: MobileSSHPlainProvider(connection: connection),
            cmuxTUIBinary: binary,
            cmuxTUIProbe: probe
        )
    }

    /// Test seam: a host whose tmux is `tmux` and that has no cmux-tui.
    static func testing(tmux: any MobileSSHWorkspaceProvider, plain: (any MobileSSHWorkspaceProvider)? = nil) -> MobileSSHHostProviders {
        MobileSSHHostProviders(
            connection: nil,
            idleCloseSeconds: nil,
            tmux: tmux,
            plain: plain ?? MobileSSHPlainProvider(connection: nil),
            cmuxTUIBinary: nil,
            cmuxTUIProbe: nil
        )
    }

    // MARK: Availability

    var availability: [MobileSSHKindAvailability] {
        MobileSSHWorkspaceKind.allCases.map { kind in
            switch kind {
            case .cmuxTUI:
                if cmuxTUIBinary != nil { return MobileSSHKindAvailability(kind: kind) }
                guard let probe = cmuxTUIProbe, probe.npmPlatformPackage != nil else {
                    let os = cmuxTUIProbe?.os ?? "?"
                    let arch = cmuxTUIProbe?.arch ?? "?"
                    return MobileSSHKindAvailability(kind: kind, unavailableReason: L10nSSH().cmuxTUIUnsupported(os: os, arch: arch))
                }
                return MobileSSHKindAvailability(kind: kind, needsInstall: true)
            case .tmux:
                return MobileSSHKindAvailability(kind: kind, unavailableReason: tmux == nil ? L10nSSH().tmuxMissing : nil)
            case .shell:
                return MobileSSHKindAvailability(kind: kind)
            }
        }
    }

    // MARK: Listing

    /// Every workspace of every kind, cmux-tui first, then tmux, then shells.
    /// A cmux-tui session whose owner does not answer is skipped; transport
    /// failures (the connection is gone) propagate.
    func listWorkspaces() async throws -> [MobileSSHWorkspace] {
        var result: [MobileSSHWorkspace] = []
        for provider in try await liveCmuxTUIProviders() {
            guard let workspaces = try? await provider.listWorkspaces() else {
                await dropCmuxTUI(session: provider.session)
                continue
            }
            result += workspaces.map { Self.rekey($0, kind: .cmuxTUI, session: provider.session) }
        }
        if let tmux {
            result += try await tmux.listWorkspaces().map { Self.rekey($0, kind: .tmux, session: nil) }
        }
        result += try await plain.listWorkspaces().map { Self.rekey($0, kind: .shell, session: nil) }
        return result
    }

    /// Providers for every session with a socket on the server, connecting
    /// new ones. Nothing is started and nothing is installed to list.
    private func liveCmuxTUIProviders() async throws -> [MobileSSHCmuxTUIProvider] {
        guard let connection, let binary = cmuxTUIBinary else { return [] }
        let sockets = try await CmuxTUIRemote(binaryPath: binary).listSessionSockets(on: connection)
        var providers: [MobileSSHCmuxTUIProvider] = []
        for socket in sockets {
            if let provider = cmuxTUI[socket.name] {
                providers.append(provider)
                continue
            }
            let provider = cmuxTUIProvider(session: socket.name, socket: socket, connection: connection, binary: binary)
            do {
                try await provider.connect()
                cmuxTUI[socket.name] = cmuxTUI[socket.name] ?? provider
                providers.append(cmuxTUI[socket.name] ?? provider)
            } catch {
                await provider.close()
            }
        }
        return providers
    }

    private func cmuxTUIProvider(
        session: String,
        socket: CmuxTUISessionSocket?,
        connection: SSHConnection,
        binary: String
    ) -> MobileSSHCmuxTUIProvider {
        // The phone's own session may be (re)started; any other session
        // belongs to whoever started it and is only ever reached.
        let route: MobileSSHCmuxTUIProvider.Route = if session == MobileSSHCmuxTUIProvider.sessionName || socket == nil {
            .ensure
        } else {
            .socket(socket!)
        }
        return MobileSSHCmuxTUIProvider(
            connection: connection,
            remote: CmuxTUIRemote(binaryPath: binary),
            session: session,
            route: route,
            idleCloseSeconds: idleCloseSeconds
        )
    }

    private func dropCmuxTUI(session: String) async {
        await cmuxTUI.removeValue(forKey: session)?.close()
    }

    /// Re-keys a provider's workspace (and its terminals and browsers) to
    /// kind-encoded local ids.
    static func rekey(_ workspace: MobileSSHWorkspace, kind: MobileSSHWorkspaceKind, session: String?) -> MobileSSHWorkspace {
        func local(_ id: String) -> String {
            switch kind {
            case .cmuxTUI: MobileSSHLocalID.cmuxTUI(session: session ?? MobileSSHCmuxTUIProvider.sessionName, id: id).rawValue
            case .tmux: MobileSSHLocalID.tmux(id).rawValue
            case .shell: MobileSSHLocalID.shell(id).rawValue
            }
        }
        var workspace = workspace
        workspace.kind = kind
        workspace.cmuxTUISession = kind == .cmuxTUI ? session : nil
        workspace.id = local(workspace.id)
        workspace.terminals = workspace.terminals.map { terminal in
            var terminal = terminal
            terminal.id = local(terminal.id)
            return terminal
        }
        workspace.browsers = workspace.browsers.map { browser in
            var browser = browser
            browser.id = local(browser.id)
            return browser
        }
        return workspace
    }

    // MARK: Dispatch

    /// The provider serving a local id, connecting a cmux-tui session on
    /// first use.
    func provider(for local: MobileSSHLocalID) async throws -> any MobileSSHWorkspaceProvider {
        switch local {
        case .tmux:
            guard let tmux else { throw MobileSSHRuntimeError.tmuxMissing }
            return tmux
        case .shell:
            return plain
        case .cmuxTUI(let session, _):
            return try await cmuxTUIProvider(session: session)
        }
    }

    /// The provider of a cmux-tui session: cached, the phone's own session
    /// (started if needed), or a live socket found on the server.
    func cmuxTUIProvider(session: String) async throws -> MobileSSHCmuxTUIProvider {
        if let provider = cmuxTUI[session] { return provider }
        guard let connection, let binary = cmuxTUIBinary else { throw MobileSSHRuntimeError.cmuxTUIMissing }
        var socket: CmuxTUISessionSocket?
        if session != MobileSSHCmuxTUIProvider.sessionName {
            socket = try await CmuxTUIRemote(binaryPath: binary).listSessionSockets(on: connection).first { $0.name == session }
            guard socket != nil else { throw MobileSSHRuntimeError.cmuxTUISessionGone }
        }
        let provider = cmuxTUIProvider(session: session, socket: socket, connection: connection, binary: binary)
        cmuxTUI[session] = provider
        return provider
    }

    /// Creates a top-level primitive of `kind` and returns it re-keyed.
    /// The first cmux-tui workspace on a host without cmux-tui installs it
    /// (PRD D10), reporting through `installing`.
    func createWorkspace(
        kind: MobileSSHWorkspaceKind,
        installing: @escaping @MainActor (Bool) -> Void
    ) async throws -> MobileSSHWorkspace {
        switch kind {
        case .shell:
            return Self.rekey(try await plain.createWorkspace(), kind: .shell, session: nil)
        case .tmux:
            guard let tmux else { throw MobileSSHRuntimeError.tmuxMissing }
            return Self.rekey(try await tmux.createWorkspace(), kind: .tmux, session: nil)
        case .cmuxTUI:
            try await installCmuxTUIIfNeeded(installing: installing)
            let provider = try await cmuxTUIProvider(session: MobileSSHCmuxTUIProvider.sessionName)
            return Self.rekey(try await provider.createWorkspace(), kind: .cmuxTUI, session: provider.session)
        }
    }

    private func installCmuxTUIIfNeeded(installing: @escaping @MainActor (Bool) -> Void) async throws {
        guard cmuxTUIBinary == nil else { return }
        guard let connection else { throw MobileSSHRuntimeError.cmuxTUIMissing }
        var probe = cmuxTUIProbe
        if probe == nil { probe = try? await CmuxTUIRemote().probe(on: connection) }
        guard let probe else { throw MobileSSHRuntimeError.cmuxTUIMissing }
        installing(true)
        defer { installing(false) }
        try await MobileSSHCmuxTUIInstaller().install(probe: probe, on: connection) { _ in }
        cmuxTUIBinary = CmuxTUIRemote.defaultBinaryPath
    }

    /// "New Window" (tmux) / "New Screen" (cmux-tui) in a workspace.
    func createTerminal(inWorkspace local: MobileSSHLocalID) async throws -> MobileSSHLocalID? {
        guard let creator = try await provider(for: local) as? any MobileSSHTerminalCreating else { return nil }
        let terminal = try await creator.createTerminal(inWorkspace: local.providerID)
        return local.sibling(terminal.id)
    }

    /// The section-level action: "Split Pane" on a tmux window, "New Tab" on
    /// a cmux-tui screen (in `pane`).
    func createTab(inWorkspace local: MobileSSHLocalID, section: String, pane: Int?) async throws -> MobileSSHLocalID? {
        switch local {
        case .tmux(let session):
            guard let tmux = tmux as? MobileSSHTmuxProvider else { throw MobileSSHRuntimeError.tmuxMissing }
            return local.sibling(try await tmux.splitWindow(inWorkspace: session, window: section).id)
        case .cmuxTUI(let session, let key):
            guard let pane else { return nil }
            let provider = try await cmuxTUIProvider(session: session)
            return local.sibling(try await provider.createTab(inWorkspace: key, pane: pane).id)
        case .shell:
            return nil
        }
    }
}

extension MobileSSHLocalID {
    /// Another id of the same kind (and cmux-tui session).
    func sibling(_ providerID: String) -> MobileSSHLocalID {
        switch self {
        case .cmuxTUI(let session, _): .cmuxTUI(session: session, id: providerID)
        case .tmux: .tmux(providerID)
        case .shell: .shell(providerID)
        }
    }
}
