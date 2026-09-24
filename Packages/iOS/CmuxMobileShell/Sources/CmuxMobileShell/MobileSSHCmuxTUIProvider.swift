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
final class MobileSSHCmuxTUIProvider: MobileSSHWorkspaceProvider {
    /// Session name owned by the phone, so a desktop `cmux` session on the
    /// same machine is never taken over.
    static let sessionName = "cmux-ios"

    private let connection: SSHConnection
    private let remote: CmuxTUIRemote
    private var control: CmuxTUIControl?

    private init(connection: SSHConnection, remote: CmuxTUIRemote) {
        self.connection = connection
        self.remote = remote
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
        return MobileSSHCmuxTUIProvider(connection: connection, remote: remote)
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
                    }
                )
            }
        }
    }

    func createWorkspace() async throws -> MobileSSHWorkspace {
        let created = try await withControl { control in
            try await control.createWorkspace(withTerminal: true, cols: 80, rows: 24)
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
            return MobileSSHCmuxTUITerminal(attachment: attachment, events: events)
        }
    }
}

@MainActor
final class MobileSSHCmuxTUITerminal: MobileSSHAttachedTerminal {
    private let attachment: CmuxTUIAttachment
    private var pump: Task<Void, Never>?

    init(attachment: CmuxTUIAttachment, events: @escaping @MainActor (MobileSSHAttachEvent) -> Void) {
        self.attachment = attachment
        pump = Task { @MainActor in
            for await event in attachment.events {
                switch event {
                case .vtState(let replay, _, _), .resized(_, _, let replay):
                    events(.snapshot(replay))
                case .output(let bytes):
                    events(.output(bytes))
                case .exited, .disconnected:
                    events(.ended)
                case .colors:
                    break
                }
            }
        }
    }

    func write(_ data: Data) async {
        try? await attachment.write(data)
    }

    func resize(columns: Int, rows: Int) async {
        _ = try? await attachment.resize(cols: columns, rows: rows)
    }

    func detach() async {
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
        tar -xzf "$t" -C "$d"; mkdir -p "$HOME/.local/bin"
        cp "$d/package/bin/cmux-tui" "$HOME/.local/bin/cmux-tui.new"; chmod 755 "$HOME/.local/bin/cmux-tui.new"
        mv -f "$HOME/.local/bin/cmux-tui.new" "$HOME/.local/bin/cmux-tui"
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
