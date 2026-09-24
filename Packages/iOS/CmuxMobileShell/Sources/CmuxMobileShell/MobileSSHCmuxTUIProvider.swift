internal import CmuxMobileSSH
import CryptoKit
import Foundation

/// cmux-tui sessions on the server (PRD D9-D12, D20): workspaces are
/// cmux-tui's own, terminals persist in its terminal-host processes, and
/// attach uses `bytes` mode (a `vt-state` snapshot, then live PTY bytes)
/// with the phone claiming geometry (D19).
///
/// Terminal ids are cmux-tui resource ids (`term_...`), which survive owner
/// restarts; numeric surface ids do not, so attach re-lists to resolve them.
@MainActor
final class MobileSSHCmuxTUIProvider: MobileSSHWorkspaceProvider, MobileSSHBrowserProviding, MobileSSHCurrentDirectoryProviding {
    /// Session name owned by the phone, so a desktop `cmux` session on the
    /// same machine is never taken over.
    static let sessionName = "cmux-ios"

    private let connection: SSHConnection
    private let remote: CmuxTUIRemote
    private var control: CmuxTUIControl?
    /// The host's idle-close setting (PRD D13), applied to every terminal the
    /// phone creates or attaches; `nil` means never close.
    private let idleCloseSeconds: Int?

    private init(connection: SSHConnection, remote: CmuxTUIRemote, idleCloseSeconds: Int?) {
        self.connection = connection
        self.remote = remote
        self.idleCloseSeconds = idleCloseSeconds
    }

    /// Ensures cmux-tui is installed (uploading it if needed, D10) and
    /// returns a provider bound to the phone's session.
    static func make(
        connection: SSHConnection,
        host: SSHHostRecord,
        progress: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> any MobileSSHWorkspaceProvider {
        let remote = CmuxTUIRemote()
        let probe = try await remote.probe(on: connection)
        // Only install when missing: never replace a cmux-tui the user
        // installed themselves (it may be newer than the pinned build).
        if probe.installed == nil {
            try await MobileSSHCmuxTUIInstaller.install(probe: probe, on: connection, progress: progress)
        }
        return MobileSSHCmuxTUIProvider(connection: connection, remote: remote, idleCloseSeconds: host.idleClose.seconds)
    }

    private func liveControl() async throws -> CmuxTUIControl {
        if let control { return control }
        let control = try await remote.connect(on: connection, session: Self.sessionName)
        self.control = control
        return control
    }

    /// Runs `body`, reconnecting the control channel once if it dropped.
    private func withControl<T>(_ body: (CmuxTUIControl) async throws -> T) async throws -> T {
        do {
            return try await body(try await liveControl())
        } catch {
            await control?.close()
            control = nil
            return try await body(try await liveControl())
        }
    }

    func listWorkspaces() async throws -> [MobileSSHWorkspace] {
        try await withControl { control in
            try await control.listWorkspaces().map { workspace in
                MobileSSHWorkspace(
                    id: workspace.key ?? "w\(workspace.id)",
                    name: workspace.name,
                    terminals: workspace.terminals.filter { !$0.dead }.map { terminal in
                        MobileSSHTerminal(
                            id: terminal.resourceID ?? "s\(terminal.surface)",
                            name: terminal.name ?? (terminal.title.isEmpty ? workspace.name : terminal.title)
                        )
                    },
                    browsers: workspace.browsers.filter { !$0.dead }.map { browser in
                        MobileSSHBrowser(
                            id: Self.browserID(browser),
                            title: browser.title,
                            url: browser.url,
                            columns: browser.cols,
                            rows: browser.rows
                        )
                    }
                )
            }
        }
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
            ?? MobileSSHWorkspace(id: created.key, name: created.key, terminals: [])
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
    /// "New Terminal": a terminal in the cmux-tui workspace with stable
    /// `workspaceID` (its key), appearing as a new tab.
    func createTerminal(inWorkspace workspaceID: String) async throws -> MobileSSHTerminal {
        let before = Set(try await listWorkspaces().first { $0.id == workspaceID }?.terminals.map(\.id) ?? [])
        let created = try await withControl { control in
            let created = try await control.createTerminal(inWorkspace: workspaceID, cols: 80, rows: 24)
            if let surface = created.surface {
                await applyIdlePolicy(surface: surface, on: control)
            }
            return created
        }
        // The listing keys terminals by resource id, which `create-terminal`
        // does not return; the new tab is the one that was not there before.
        let terminals = try await listWorkspaces().first { $0.id == workspaceID }?.terminals ?? []
        return terminals.first { !before.contains($0.id) }
            ?? MobileSSHTerminal(id: created.terminalID, name: created.terminalID)
    }
}

extension MobileSSHCmuxTUIProvider {
    /// Browser content ids (`brw_...`) survive owner restarts; numeric
    /// surface ids do not, so they are only a fallback.
    static func browserID(_ browser: CmuxTUIBrowserTab) -> String {
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
            guard let fresh = try await current.control.reattach(current, cols: grid.columns, rows: grid.rows) else {
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
        _ = try? await attachment.resize(cols: columns, rows: rows)
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
enum MobileSSHCmuxTUIInstaller {
    /// The cmux-tui release this app build speaks to.
    static let pinnedVersion = "0.13.4"

    enum InstallError: Error, Equatable {
        case unsupportedPlatform(os: String, arch: String)
        case integrityMismatch
        case registry(String)
        case remoteInstallFailed(String)
    }

    static func install(
        probe: CmuxTUIProbe,
        on connection: SSHConnection,
        binDirectory: String = "$HOME/.local/bin",
        progress: @escaping @MainActor (String) -> Void
    ) async throws {
        guard let package = probe.npmPlatformPackage else {
            throw InstallError.unsupportedPlatform(os: probe.os, arch: probe.arch)
        }
        await progress(L10nSSH.installingCmuxTUI)
        let tarball = try await download(package: package, version: pinnedVersion)
        let remoteTar = "/tmp/cmux-tui-\(UUID().uuidString).tgz"
        let upload = try await connection.exec("umask 077; cat > \(MobileSSHShell.quote(remoteTar))", stdin: tarball)
        guard upload.exitStatus == 0 else { throw InstallError.remoteInstallFailed(upload.stderrString) }
        let script = """
        set -e; t=\(MobileSSHShell.quote(remoteTar)); d=$(mktemp -d); trap 'rm -rf "$d" "$t"' EXIT
        b="\(binDirectory)"; tar -xzf "$t" -C "$d"; mkdir -p "$b"
        cp "$d/package/bin/cmux-tui" "$b/cmux-tui.new"; chmod 755 "$b/cmux-tui.new"
        mv -f "$b/cmux-tui.new" "$b/cmux-tui"
        """
        let result = try await connection.exec("sh -c " + MobileSSHShell.quote(script))
        guard result.exitStatus == 0 else { throw InstallError.remoteInstallFailed(result.stderrString) }
    }

    /// Downloads the tarball (cached per version) and verifies npm's
    /// `dist.integrity` SHA-512.
    static func download(package: String, version: String) async throws -> Data {
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
        if let cached = try? Data(contentsOf: cache), sha512Base64(cached) == expected {
            return cached
        }
        let (data, _) = try await URLSession.shared.data(from: tarballURL)
        guard sha512Base64(data) == expected else { throw InstallError.integrityMismatch }
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cache, options: .atomic)
        return data
    }

    static func sha512Base64(_ data: Data) -> String {
        Data(SHA512.hash(data: data)).base64EncodedString()
    }
}
