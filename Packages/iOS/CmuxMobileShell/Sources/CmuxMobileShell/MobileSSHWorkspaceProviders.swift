internal import CmuxMobileSSH
internal import CmuxMobileSupport
import Foundation

/// One workspace on an SSH computer. Providers return their own ids; the
/// host registry (``MobileSSHHostProviders``) re-keys every id to its
/// kind-encoded ``MobileSSHLocalID`` form before the runtime sees it.
struct MobileSSHWorkspace: Equatable, Sendable {
    var id: String
    var name: String
    var terminals: [MobileSSHTerminal]
    /// Streamable browser tabs (cmux-tui with a `cmux-browser` provider only).
    var browsers: [MobileSSHBrowser] = []
    var kind: MobileSSHWorkspaceKind = .shell
    /// The nested grouping the tab switcher shows (tmux windows, cmux-tui
    /// screens), in order. Empty for shells.
    var sections: [MobileSSHWorkspaceSection] = []
    /// The cmux-tui session holding the workspace; `nil` for other kinds.
    var cmuxTUISession: String?
}

/// One tmux window or cmux-tui screen of a workspace.
struct MobileSSHWorkspaceSection: Equatable, Sendable {
    /// Provider-scoped: tmux window index, cmux-tui screen id.
    var id: String
    var title: String
    /// The pane a section-level New Tab goes to (cmux-tui active pane).
    var targetPane: Int?
}

/// Where a terminal sits inside its workspace, for the grouped tab switcher.
struct MobileSSHTerminalPlacement: Equatable, Sendable {
    /// ``MobileSSHWorkspaceSection/id`` of its window or screen.
    var sectionID: String
    /// Its pane, unique within the workspace.
    var paneID: String
    /// Short row title inside the section.
    var title: String
    /// Names the pane when its section has several (`Pane 2`).
    var paneLabel: String?
}

/// One browser tab on an SSH computer, in host-local ids.
struct MobileSSHBrowser: Equatable, Sendable {
    var id: String
    var title: String
    var url: String?
    /// Server-side cell grid, used to estimate the page size before the
    /// first frame arrives.
    var columns: Int?
    var rows: Int?
}

/// Output from a browser attachment, in order.
enum MobileSSHBrowserEvent: Sendable {
    /// Page metadata. `failure` carries raw runtime text when the browser failed.
    case state(url: String?, title: String, isLoading: Bool, failure: String?)
    /// One PNG bitmap. Page size is in CSS pixels (pointer coordinate space).
    case frame(sequence: UInt64, pageWidth: Double, pageHeight: Double, pixelWidth: Int, pixelHeight: Int, base64PNG: String)
    /// The stream ended (tab closed, transport lost, or detached).
    case ended
}

/// A live browser attachment: input, navigation, and presentation acks.
/// Coordinates are page CSS pixels, the space frames report.
@MainActor
protocol MobileSSHAttachedBrowser: AnyObject {
    /// Called once a frame's pixels are on screen; unlocks pointer input.
    func frameDisplayed(sequence: UInt64) async throws
    func click(x: Double, y: Double, clickCount: Int) async throws
    func pointer(down: Bool, x: Double, y: Double, clickCount: Int) async throws
    func scroll(x: Double, y: Double, deltaY: Double) async throws
    func key(_ token: String, modifiers: [String]) async throws
    func text(_ text: String) async throws
    func navigate(_ url: String) async throws
    func back() async throws
    func forward() async throws
    func reload() async throws
    /// Reports the phone's viewport in points.
    func viewport(width: Int, height: Int) async throws
    func detach() async
}

/// Providers whose workspaces can contain streamable browser tabs.
@MainActor
protocol MobileSSHBrowserProviding: AnyObject {
    func attachBrowser(
        browserID: String,
        viewport: (width: Int, height: Int)?,
        events: @escaping @MainActor (MobileSSHBrowserEvent) -> Void
    ) async throws -> any MobileSSHAttachedBrowser
}

struct MobileSSHTerminal: Equatable, Sendable {
    var id: String
    var name: String
    var placement: MobileSSHTerminalPlacement? = nil
}

/// A live terminal attachment. Output flows through the callback given to
/// ``MobileSSHWorkspaceProvider/attach``; this handle carries input and size.
@MainActor
protocol MobileSSHAttachedTerminal: AnyObject {
    func write(_ data: Data) async
    func resize(columns: Int, rows: Int) async
    /// Leaves the remote session running (persistent modes) or ends it (plain).
    func detach() async
    /// The terminal left the screen: give up any geometry claim while
    /// keeping the stream warm. The next ``resize(columns:rows:)`` claims
    /// again (cmux-tui, PRD D33).
    func releaseGeometry() async
}

extension MobileSSHAttachedTerminal {
    func releaseGeometry() async {}
}

/// Output from an attachment, in order.
enum MobileSSHAttachEvent: Sendable {
    /// Replace the local screen with this snapshot (cmux-tui `vt-state`).
    case snapshot(Data)
    case output(Data)
    /// The remote terminal renders at this fixed grid (a tmux pane inside a
    /// split window): the phone pins its surface to it and letterboxes
    /// instead of resizing a PTY the pane does not own.
    case remoteGrid(columns: Int, rows: Int)
    /// The remote side ended (shell exited, session killed, connection lost).
    case ended
}

/// How one workspace kind lists, creates, and attaches workspaces (PRD D22, D31).
@MainActor
protocol MobileSSHWorkspaceProvider: AnyObject {
    func listWorkspaces() async throws -> [MobileSSHWorkspace]
    func createWorkspace() async throws -> MobileSSHWorkspace
    func closeWorkspace(id: String) async throws
    func attach(
        terminalID: String,
        columns: Int,
        rows: Int,
        events: @escaping @MainActor (MobileSSHAttachEvent) -> Void
    ) async throws -> any MobileSSHAttachedTerminal
}

// MARK: - Channel-backed attachment (plain, tmux)

@MainActor
final class MobileSSHChannelTerminal: MobileSSHAttachedTerminal {
    private let channel: SSHSessionChannel
    private var pump: Task<Void, Never>?

    init(channel: SSHSessionChannel, events: @escaping @MainActor (MobileSSHAttachEvent) -> Void) {
        self.channel = channel
        pump = Task { @MainActor in
            for await event in channel.events {
                switch event {
                case .stdout(let data), .stderr(let data):
                    events(.output(data))
                case .closed:
                    events(.ended)
                case .exitStatus, .exitSignal:
                    break
                }
            }
        }
    }

    func write(_ data: Data) async {
        try? await channel.write(data)
    }

    func resize(columns: Int, rows: Int) async {
        try? await channel.resize(columns: columns, rows: rows)
    }

    func detach() async {
        pump?.cancel()
        await channel.close()
    }
}

// MARK: - Plain

/// Shells opened from this phone. Nothing persists: each workspace is one
/// login shell that ends when its channel closes. Ids are `1`, `2`, ...
@MainActor
final class MobileSSHPlainProvider: MobileSSHWorkspaceProvider {
    /// `nil` only in tests, where shells cannot attach.
    private let connection: SSHConnection?
    private var workspaces: [MobileSSHWorkspace] = []
    private var counter = 0

    init(connection: SSHConnection?) {
        self.connection = connection
    }

    func listWorkspaces() async throws -> [MobileSSHWorkspace] { workspaces }

    func createWorkspace() async throws -> MobileSSHWorkspace {
        counter += 1
        let id = String(counter)
        let name = L10n.string("mobile.ssh.workspace.shellName", defaultValue: "Shell \(counter)")
        let workspace = MobileSSHWorkspace(id: id, name: name, terminals: [MobileSSHTerminal(id: id, name: name)], kind: .shell)
        workspaces.append(workspace)
        return workspace
    }

    func closeWorkspace(id: String) async throws {
        workspaces.removeAll { $0.id == id }
    }

    func attach(
        terminalID: String,
        columns: Int,
        rows: Int,
        events: @escaping @MainActor (MobileSSHAttachEvent) -> Void
    ) async throws -> any MobileSSHAttachedTerminal {
        guard let connection else { throw SSHConnectionError.closed }
        let channel = try await connection.openSession(
            pty: SSHPTYRequest(columns: columns, rows: rows),
            environment: ["LANG": "en_US.UTF-8"],
            start: .shell
        )
        return MobileSSHChannelTerminal(channel: channel) { [weak self] event in
            if case .ended = event { self?.workspaces.removeAll { $0.id == terminalID } }
            events(event)
        }
    }
}
