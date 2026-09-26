internal import CmuxMobileSSH
internal import CmuxMobileSupport
import CryptoKit
import Foundation

/// One cmux-tui session on the server (PRD D9-D12, D20, D31): workspaces
/// are cmux-tui's own, terminals persist in its terminal-host processes, and
/// attach uses `bytes` mode (a `vt-state` snapshot, then live PTY bytes)
/// with the phone claiming geometry while the terminal is on screen (D33).
///
/// The phone's own session (``sessionName``) is started on demand with
/// `server ensure`; every other session was started elsewhere (a laptop)
/// and is reached through its existing socket, never started.
///
/// Terminal ids are cmux-tui resource ids (`term_...`), which survive owner
/// restarts; numeric surface ids do not, so attach re-lists to resolve them.
@MainActor
final class MobileSSHCmuxTUIProvider: MobileSSHWorkspaceProvider, MobileSSHBrowserProviding, MobileSSHCurrentDirectoryProviding,
    MobileSSHTopologyReporting {
    /// Session name owned by the phone, so a desktop `cmux` session on the
    /// same machine is never taken over when the phone creates workspaces.
    nonisolated static let sessionName = "cmux-ios"

    /// How the provider reaches its session's owner.
    enum Route: Equatable {
        /// `server ensure` + `relay --session` (the phone's own session).
        case ensure
        /// `relay --socket` to an owner someone else started.
        case socket(CmuxTUISessionSocket)
    }

    /// The session name. A hashed socket (a very long name) does not carry
    /// it, so it starts as the socket's digest and becomes the name the
    /// owner reports once connected.
    private(set) var session: String
    private let connection: SSHConnection
    private let remote: CmuxTUIRemote
    private let route: Route
    private var control: CmuxTUIControl?
    /// Session-wide notifications of the live control (`subscribe`).
    private var subscription: Task<Void, Never>?
    private var topology = MobileSSHCmuxTUITopologyGate()
    /// Called when the session's tree changed elsewhere (a laptop added a
    /// screen or tab, a terminal exited), at most once per listing.
    var onTopologyChange: (@MainActor () -> Void)?
    /// The host's idle-close setting (PRD D13), applied to every terminal the
    /// phone creates or attaches; `nil` means never close.
    private let idleCloseSeconds: Int?

    init(connection: SSHConnection, remote: CmuxTUIRemote, session: String, route: Route, idleCloseSeconds: Int?) {
        self.connection = connection
        self.remote = remote
        self.session = session
        self.route = route
        self.idleCloseSeconds = idleCloseSeconds
    }

    private func liveControl() async throws -> CmuxTUIControl {
        if let control { return control }
        let control = switch route {
        case .ensure: try await remote.connect(on: connection, session: session)
        case .socket(let socket): try await remote.connect(on: connection, socket: socket)
        }
        if let current = self.control {
            // A concurrent caller connected first; keep one connection.
            await control.close()
            return current
        }
        self.control = control
        if case .socket(let socket) = route, socket.name == nil {
            session = await control.session
        }
        watchTopology(of: control)
        return control
    }

    /// Relists promptly when the tree changes elsewhere: `subscribe` on the
    /// control connection streams `tree-changed` (workspaces, screens, panes,
    /// tabs, names, selection) and `surface-exited`. No polling; a dropped
    /// connection ends the watch and the next connection starts a new one.
    private func watchTopology(of control: CmuxTUIControl) {
        subscription?.cancel()
        subscription = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let events = try? await control.subscribe() else { return }
                var resubscribe = false
                for await event in events {
                    guard let self, self.control === control else { return }
                    switch event {
                    case .overflow:
                        resubscribe = true
                    case .disconnected:
                        // The owner exited (or the relay died) while the SSH
                        // connection lives: relist so its rows go away. A
                        // closed SSH connection is the runtime's to report.
                        self.control = nil
                        guard self.connection.isOpen else { return }
                    default:
                        break
                    }
                    if self.topology.admit(event) { self.onTopologyChange?() }
                }
                // The server ends a subscriber that fell behind; anything
                // else (disconnect) ends the watch.
                guard resubscribe, let self, self.control === control else { return }
            }
        }
    }

    /// Opens the control connection now (discovery skips sessions whose
    /// owner does not answer).
    func connect() async throws {
        _ = try await liveControl()
    }

    func close() async {
        subscription?.cancel()
        subscription = nil
        await control?.close()
        control = nil
    }

    /// Runs `body`, reconnecting the control channel once if it dropped.
    private func withControl<T>(_ body: (CmuxTUIControl) async throws -> T) async throws -> T {
        do {
            return try await body(try await liveControl())
        } catch {
            subscription?.cancel()
            subscription = nil
            await control?.close()
            control = nil
            return try await body(try await liveControl())
        }
    }

    func listWorkspaces() async throws -> [MobileSSHWorkspace] {
        // This listing observes every change reported so far.
        topology.listed()
        return try await withControl { control in
            try await control.listWorkspaces().map(Self.workspace)
        }
    }

    /// Maps a cmux-tui workspace to its row: terminals in layout order, one
    /// tab-switcher section per screen, tabs grouped by pane.
    nonisolated static func workspace(_ workspace: CmuxTUIWorkspace) -> MobileSSHWorkspace {
        var sections: [MobileSSHWorkspaceSection] = []
        var screenPanes: [Int: [Int]] = [:]
        for (index, screen) in workspace.screens.enumerated() {
            let title = screen.name.flatMap { $0.isEmpty ? nil : $0 }
                ?? L10n.string("mobile.ssh.tabs.screenName", defaultValue: "Screen \(index + 1)")
            sections.append(MobileSSHWorkspaceSection(
                id: String(screen.id),
                title: title,
                targetPane: screen.activePane ?? screen.panes.first?.id
            ))
            screenPanes[screen.id] = screen.panes.map(\.id)
        }
        let live = workspace.terminals.filter { !$0.dead }
        return MobileSSHWorkspace(
            id: workspace.key ?? "w\(workspace.id)",
            name: workspace.name,
            terminals: live.map { terminal in
                let name = terminal.name ?? (terminal.title.isEmpty ? workspace.name : terminal.title)
                let panes = screenPanes[terminal.screen] ?? []
                let position = (panes.firstIndex(of: terminal.pane) ?? 0) + 1
                return MobileSSHTerminal(
                    id: terminal.resourceID ?? "s\(terminal.surface)",
                    name: name,
                    placement: MobileSSHTerminalPlacement(
                        sectionID: String(terminal.screen),
                        paneID: String(terminal.pane),
                        title: name,
                        paneLabel: panes.count > 1
                            ? L10n.string("mobile.ssh.tabs.paneLabel", defaultValue: "Pane \(position)")
                            : nil
                    )
                )
            },
            browsers: workspace.browsers.filter { !$0.dead }.map { browser in
                MobileSSHBrowser(
                    id: browserID(browser),
                    title: browser.title,
                    url: browser.url,
                    columns: browser.cols,
                    rows: browser.rows
                )
            },
            kind: .cmuxTUI,
            sections: sections
        )
    }

    func createWorkspace() async throws -> MobileSSHWorkspace {
        let created = try await withControl { control in
            let created = try await control.createWorkspace(withTerminal: true, cols: 80, rows: 24)
            if let surface = created.terminal?.surface {
                await applyIdlePolicy(surface: surface, on: control)
            }
            return created
        }
        let listed = try await listWorkspaces()
        return listed.first { $0.id == created.key }
            ?? MobileSSHWorkspace(id: created.key, name: created.key, terminals: [], kind: .cmuxTUI)
    }

    func closeWorkspace(id: String) async throws {
        try await withControl { control in
            try await control.closeWorkspace(key: id, closeTerminals: true)
        }
    }

    func attach(
        terminalID: String,
        columns: Int,
        rows: Int,
        events: @escaping @MainActor (MobileSSHAttachEvent) -> Void
    ) async throws -> any MobileSSHAttachedTerminal {
        try await withControl { control in
            let terminals = try await control.listWorkspaces().flatMap(\.terminals)
            guard let terminal = terminals.first(where: { ($0.resourceID ?? "s\($0.surface)") == terminalID }) else {
                throw CmuxTUIError.commandFailed(command: "attach-surface", message: "terminal \(terminalID) is gone", code: nil)
            }
            let attachment = try await control.attach(surface: terminal.surface, cols: columns, rows: rows)
            await applyIdlePolicy(surface: terminal.surface, on: control)
            return MobileSSHCmuxTUITerminal(attachment: attachment, columns: columns, rows: rows, events: events)
        }
    }

    /// Stores the host's idle-close policy on one terminal (PRD D13). A
    /// server without `terminal-idle-close-v1` ignores it, and a failure never
    /// blocks the session: the terminal then simply keeps running.
    private func applyIdlePolicy(surface: Int, on control: CmuxTUIControl) async {
        _ = try? await control.setIdlePolicy(surface: surface, seconds: idleCloseSeconds)
    }

    /// The terminal's live working directory from cmux-tui `process-info`
    /// (follows `cd` in the foreground shell), for the Files chip.
    func currentDirectory(terminalID: String) async -> String? {
        try? await withControl { control in
            let terminals = try await control.listWorkspaces().flatMap(\.terminals)
            guard let terminal = terminals.first(where: { ($0.resourceID ?? "s\($0.surface)") == terminalID }) else {
                return nil
            }
            return try await control.workingDirectory(surface: terminal.surface)
        }
    }
}

extension MobileSSHCmuxTUIProvider: MobileSSHTerminalCreating {
    /// "New Screen": a screen (one pane, one terminal) in the workspace with
    /// stable `workspaceID` (its key).
    func createTerminal(inWorkspace workspaceID: String) async throws -> MobileSSHTerminal {
        try await createSurface(inWorkspace: workspaceID) { control, workspace in
            try await control.newScreen(workspace: workspace.id, cols: 80, rows: 24)
        }
    }

    /// "New Tab" on a screen section: a terminal tab in the screen's active
    /// pane.
    func createTab(inWorkspace workspaceID: String, pane: Int) async throws -> MobileSSHTerminal {
        try await createSurface(inWorkspace: workspaceID) { control, _ in
            try await control.newTab(pane: pane, cols: 80, rows: 24)
        }
    }

    /// "Split Pane" on a screen section: splits the screen's active pane to
    /// the right (`split`), like tmux's Split Pane on a window. The new pane
    /// holds one terminal tab.
    func splitPane(inWorkspace workspaceID: String, pane: Int) async throws -> MobileSSHTerminal {
        try await createSurface(inWorkspace: workspaceID) { control, _ in
            try await control.split(pane: pane, direction: .right, cols: 80, rows: 24)
        }
    }

    /// Runs a creation command against the live workspace and returns the
    /// tab it added. The listing keys terminals by resource id, which the
    /// commands do not return; the new tab is the surface they report.
    private func createSurface(
        inWorkspace workspaceID: String,
        _ create: (CmuxTUIControl, CmuxTUIWorkspace) async throws -> Int
    ) async throws -> MobileSSHTerminal {
        let surface = try await withControl { control in
            guard let workspace = try await control.listWorkspaces().first(where: { $0.key == workspaceID }) else {
                throw CmuxTUIError.commandFailed(command: "create", message: "workspace \(workspaceID) is gone", code: nil)
            }
            let surface = try await create(control, workspace)
            await applyIdlePolicy(surface: surface, on: control)
            return surface
        }
        let workspace = try await withControl { control in
            try await control.listWorkspaces().first { $0.key == workspaceID }
        }
        if let workspace, let created = workspace.terminals.first(where: { $0.surface == surface }) {
            let id = created.resourceID ?? "s\(surface)"
            return Self.workspace(workspace).terminals.first { $0.id == id } ?? MobileSSHTerminal(id: id, name: id)
        }
        return MobileSSHTerminal(id: "s\(surface)", name: "s\(surface)")
    }
}

extension MobileSSHCmuxTUIProvider {
    /// Browser content ids (`brw_...`) survive owner restarts; numeric
    /// surface ids do not, so they are only a fallback.
    nonisolated static func browserID(_ browser: CmuxTUIBrowserTab) -> String {
        browser.resourceID ?? "b\(browser.surface)"
    }

    func attachBrowser(
        browserID: String,
        viewport: (width: Int, height: Int)?,
        events: @escaping @MainActor (MobileSSHBrowserEvent) -> Void
    ) async throws -> any MobileSSHAttachedBrowser {
        try await withControl { control in
            guard await control.supportsBrowserAttach else {
                throw CmuxTUIError.missingCapability(CmuxTUIControl.browserPointerGuardCapability)
            }
            let browsers = try await control.listWorkspaces().flatMap(\.browsers)
            guard let browser = browsers.first(where: { Self.browserID($0) == browserID }) else {
                throw CmuxTUIError.commandFailed(command: "attach-surface", message: "browser \(browserID) is gone", code: nil)
            }
            let cell = try await control.cellPixels()
            let grid = viewport.map { MobileSSHCmuxTUIBrowser.grid(width: $0.width, height: $0.height, cell: cell) }
            let attachment = try await control.attachBrowser(surface: browser.surface, cols: grid?.cols, rows: grid?.rows)
            return MobileSSHCmuxTUIBrowser(attachment: attachment, cell: cell, grid: grid, events: events)
        }
    }
}

/// One cmux-tui browser attach stream adapted to the phone's streamed
/// browser view: PNG frames pass through as base64, the pointer guard
/// (`browser-pointer-frame-guard-v1`) gates input on presented frames, and
/// the phone's point viewport becomes a cell grid via the session cell size.
@MainActor
final class MobileSSHCmuxTUIBrowser: MobileSSHAttachedBrowser {
    private let attachment: CmuxTUIBrowserAttachment
    private let cell: (width: Int, height: Int)
    private var grid: (cols: Int, rows: Int)?
    private var pointerGuard = CmuxTUIBrowserPointerGuard()
    /// Image sequence to pointer token, for frames not yet displayed.
    private var pointerTokenBySequence: [UInt64: UInt64] = [:]
    private var pump: Task<Void, Never>?
    private var control: CmuxTUIControl { attachment.control }
    private var surface: Int { attachment.surface }

    init(
        attachment: CmuxTUIBrowserAttachment,
        cell: (width: Int, height: Int),
        grid: (cols: Int, rows: Int)?,
        events: @escaping @MainActor (MobileSSHBrowserEvent) -> Void
    ) {
        self.attachment = attachment
        self.cell = cell
        self.grid = grid
        pump = Task { @MainActor [weak self] in
            for await event in attachment.events {
                guard let self else { return }
                switch event {
                case .state(let state):
                    self.pointerGuard.apply(state)
                    if var frame = state.frame {
                        frame.status = state.status
                        events(self.admit(frame))
                    }
                    events(.state(
                        url: state.url.isEmpty ? nil : state.url,
                        title: state.title,
                        isLoading: state.status == .starting,
                        failure: state.status == .failed ? (state.error ?? "") : nil
                    ))
                case .frame(let frame):
                    self.pointerGuard.apply(frame)
                    events(self.admit(frame))
                case .ended, .disconnected:
                    events(.ended)
                }
            }
        }
    }

    static func grid(width: Int, height: Int, cell: (width: Int, height: Int)) -> (cols: Int, rows: Int) {
        (max(1, width / max(1, cell.width)), max(1, height / max(1, cell.height)))
    }

    private func admit(_ frame: CmuxTUIBrowserFrame) -> MobileSSHBrowserEvent {
        if let token = frame.pointerFrameSeq {
            pointerTokenBySequence[frame.seq] = token
            // Only the newest few frames can still be displayed.
            if pointerTokenBySequence.count > 8, let oldest = pointerTokenBySequence.keys.min() {
                pointerTokenBySequence[oldest] = nil
            }
        }
        return .frame(
            sequence: frame.seq,
            pageWidth: Double(frame.width),
            pageHeight: Double(frame.height),
            pixelWidth: frame.imageWidth,
            pixelHeight: frame.imageHeight,
            base64PNG: frame.base64PNG
        )
    }

    func frameDisplayed(sequence: UInt64) async throws {
        for stale in pointerTokenBySequence.keys where stale < sequence {
            pointerTokenBySequence[stale] = nil
        }
        guard let token = pointerTokenBySequence.removeValue(forKey: sequence),
              pointerGuard.acknowledge(token) else { return }
        try await control.presentBrowserFrame(surface: surface, token: token)
    }

    /// The presented token, or `nil` while the page is navigating, resizing,
    /// or has not shown a frame yet (the server would reject the input).
    private var token: UInt64? { pointerGuard.pointerToken }

    func click(x: Double, y: Double, clickCount: Int) async throws {
        guard let token else { return }
        try await control.browserMouse(surface: surface, kind: .down, x: x, y: y, clickCount: clickCount, token: token)
        try await control.browserMouse(surface: surface, kind: .up, x: x, y: y, clickCount: clickCount, token: token)
    }

    func pointer(down: Bool, x: Double, y: Double, clickCount: Int) async throws {
        guard let token else { return }
        try await control.browserMouse(surface: surface, kind: down ? .down : .up, x: x, y: y, clickCount: clickCount, token: token)
    }

    func scroll(x: Double, y: Double, deltaY: Double) async throws {
        guard deltaY != 0, let token else { return }
        try await control.browserWheel(surface: surface, x: x, y: y, deltaY: deltaY, token: token)
    }

    func key(_ token: String, modifiers: [String]) async throws {
        guard let key = CmuxTUIBrowserKey.named(token, modifiers: modifiers) else { return }
        try await control.browserKeyPress(surface: surface, key: key)
    }

    func text(_ text: String) async throws {
        try await control.browserInsertText(surface: surface, text: text)
    }

    func navigate(_ url: String) async throws {
        try await control.browserNavigate(surface: surface, url: url)
    }

    func back() async throws { try await control.browser(.back, surface: surface) }
    func forward() async throws { try await control.browser(.forward, surface: surface) }
    func reload() async throws { try await control.browser(.reload, surface: surface) }

    func viewport(width: Int, height: Int) async throws {
        let next = Self.grid(width: width, height: height, cell: cell)
        if let grid, grid == next { return }
        grid = next
        try await control.resizeBrowser(surface: surface, cols: next.cols, rows: next.rows)
    }

    func detach() async {
        pump?.cancel()
        try? await attachment.detach()
    }
}

@MainActor
final class MobileSSHCmuxTUITerminal: MobileSSHAttachedTerminal {
    /// The live stream; replaced when a resync reattaches.
    private var attachment: CmuxTUIAttachment
    /// The phone's latest grid, reclaimed by a resync.
    private var grid: (columns: Int, rows: Int)
    private var detached = false
    /// The terminal is off screen and gave up geometry (PRD D33): a laptop
    /// on the same session may size it until the phone shows it again.
    private var geometryReleased = false
    private var pump: Task<Void, Never>?

    private enum Resync {
        case replaced(CmuxTUIAttachment)
        /// The old stream is intact (or the terminal was detached).
        case unchanged
        /// The old stream was detached but no new stream attached.
        case lost
    }

    init(
        attachment: CmuxTUIAttachment,
        columns: Int,
        rows: Int,
        events: @escaping @MainActor (MobileSSHAttachEvent) -> Void
    ) {
        self.attachment = attachment
        self.grid = (columns, rows)
        pump = Task { @MainActor [weak self] in
            var current = attachment
            var stream = attachment.events.makeAsyncIterator()
            let canResync = await attachment.control.canReattach(attachment)
            var screen = CmuxTUIAlternateScreenTracker()
            // A `vt-state`/`resized` replay of an alternate-screen program
            // (vim, less, a coding agent) carries only that screen, so the
            // local primary screen and history stay blank after it exits.
            var snapshotWasAlternate = false
            while let event = await stream.next() {
                switch event {
                case .vtState(let replay, _, _), .resized(_, _, let replay):
                    screen = CmuxTUIAlternateScreenTracker()
                    screen.feed(replay)
                    snapshotWasAlternate = screen.isAlternate
                    events(.snapshot(replay))
                case .output(let bytes):
                    events(.output(bytes))
                    guard screen.feed(bytes), snapshotWasAlternate, canResync else { continue }
                    // The program left the alternate screen: fetch the
                    // server's primary screen, which has the full history.
                    switch await self?.resync(from: current) ?? .unchanged {
                    case .replaced(let fresh):
                        current = fresh
                        stream = fresh.events.makeAsyncIterator()
                        snapshotWasAlternate = false
                    case .unchanged:
                        snapshotWasAlternate = false
                    case .lost:
                        events(.ended)
                        return
                    }
                case .exited, .disconnected:
                    events(.ended)
                case .colors:
                    break
                }
            }
        }
    }

    /// Reattaches on the same connection. The old stream's remaining frames
    /// are superseded: the new stream starts with a fresh `vt-state` that
    /// replaces the local screen through the normal snapshot path.
    private func resync(from current: CmuxTUIAttachment) async -> Resync {
        guard !detached else { return .unchanged }
        do {
            guard let fresh = try await current.control.reattach(
                current,
                cols: grid.columns,
                rows: grid.rows,
                claimGeometry: !geometryReleased
            ) else {
                return .unchanged
            }
            if detached {
                try? await fresh.detach()
                return .unchanged
            }
            attachment = fresh
            return .replaced(fresh)
        } catch {
            // A failed attach after a successful detach leaves no stream.
            return await current.control.isAttached(surface: current.surface) ? .unchanged : .lost
        }
    }

    func write(_ data: Data) async {
        try? await attachment.write(data)
    }

    func resize(columns: Int, rows: Int) async {
        grid = (columns, rows)
        if geometryReleased {
            // Back on screen: the phone owns the grid again (D19).
            geometryReleased = false
            try? await attachment.control.claimGeometry(attachment, cols: columns, rows: rows)
            return
        }
        _ = try? await attachment.resize(cols: columns, rows: rows)
    }

    /// Off screen: keep the stream, stop owning the grid. cmux-tui then
    /// freezes the grid at the phone's size until another view claims it
    /// (a laptop's cmux-tui does on focus or pane selection).
    func releaseGeometry() async {
        guard !geometryReleased, !detached else { return }
        geometryReleased = (try? await attachment.control.releaseGeometry(attachment)) ?? false
    }

    func detach() async {
        detached = true
        try? await attachment.detach()
        pump?.cancel()
    }
}

/// Puts a pinned cmux-tui build on the server without the server needing
/// internet or Node (PRD D10): the phone downloads the npm platform tarball,
/// checks its registry integrity hash, streams it over SSH, and the server
/// unpacks it with `tar` into `~/.local/bin/cmux-tui`.
struct MobileSSHCmuxTUIInstaller {
    /// The cmux-tui release this app build speaks to.
    static let pinnedVersion = "0.13.4"

    /// The remote directory the binary lands in, as a shell word that may
    /// reference `$HOME`.
    let binDirectory: String

    init(binDirectory: String = "$HOME/.local/bin") {
        self.binDirectory = binDirectory
    }

    enum InstallError: Error, Equatable {
        case unsupportedPlatform(os: String, arch: String)
        case integrityMismatch
        case registry(String)
        case remoteInstallFailed(String)
    }

    func install(
        probe: CmuxTUIProbe,
        on connection: SSHConnection,
        progress: @escaping @MainActor (String) -> Void
    ) async throws {
        guard let package = probe.npmPlatformPackage else {
            throw InstallError.unsupportedPlatform(os: probe.os, arch: probe.arch)
        }
        await progress(L10nSSH().installingCmuxTUI)
        let tarball = try await download(package: package, version: Self.pinnedVersion)
        let remoteTar = "/tmp/cmux-tui-\(UUID().uuidString).tgz"
        let upload = try await connection.exec("umask 077; cat > \(remoteTar.posixShellSingleQuoted)", stdin: tarball)
        guard upload.exitStatus == 0 else { throw InstallError.remoteInstallFailed(upload.stderrString) }
        let script = """
        set -e; t=\(remoteTar.posixShellSingleQuoted); d=$(mktemp -d); trap 'rm -rf "$d" "$t"' EXIT
        b="\(binDirectory)"; tar -xzf "$t" -C "$d"; mkdir -p "$b"
        cp "$d/package/bin/cmux-tui" "$b/cmux-tui.new"; chmod 755 "$b/cmux-tui.new"
        mv -f "$b/cmux-tui.new" "$b/cmux-tui"
        """
        let result = try await connection.exec("sh -c " + script.posixShellSingleQuoted)
        guard result.exitStatus == 0 else { throw InstallError.remoteInstallFailed(result.stderrString) }
    }

    /// Downloads the tarball (cached per version) and verifies npm's
    /// `dist.integrity` SHA-512.
    func download(package: String, version: String) async throws -> Data {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux-tui/\(package)-\(version).tgz")
        let metadataURL = URL(string: "https://registry.npmjs.org/\(package)/\(version)")!
        let (metadata, _) = try await URLSession.shared.data(from: metadataURL)
        guard let json = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let dist = json["dist"] as? [String: Any],
              let integrity = dist["integrity"] as? String, integrity.hasPrefix("sha512-"),
              let tarballString = dist["tarball"] as? String, let tarballURL = URL(string: tarballString) else {
            throw InstallError.registry("missing dist metadata for \(package)@\(version)")
        }
        let expected = String(integrity.dropFirst("sha512-".count))
        if let cached = try? Data(contentsOf: cache), cached.sha512Base64 == expected {
            return cached
        }
        let (data, _) = try await URLSession.shared.data(from: tarballURL)
        guard data.sha512Base64 == expected else { throw InstallError.integrityMismatch }
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cache, options: .atomic)
        return data
    }

}

extension Data {
    /// The base64 SHA-512 digest, as npm's `dist.integrity` spells it after `sha512-`.
    var sha512Base64: String {
        Data(SHA512.hash(data: self)).base64EncodedString()
    }
}
