import Foundation
import Testing
@testable import CmuxNextDaemon

/// Finds a real cmux-tui: `CMUX_NEXT_TUI_BIN`, else the pinned hosted
/// artifact (scripts/cmux-next/cmux-tui.pin; fetched and sha256-checked
/// with `scripts/cmux-next/pin-cmux-tui.sh fetch` on first use, as
/// scripts/reload.sh does, so a fresh worktree tests the pinned daemon),
/// else the newest client that scripts/install-cmux-tui-client.sh cached.
/// Cached slices are not executable, so they are copied into a temp dir
/// first.
enum RealBinary {
    static let url: URL? = locate()

    /// True when `url` is the pinned hosted build or an explicit override,
    /// which serve the cmux-next capabilities (release clients do not).
    static var isBranchBuild: Bool {
        guard let url else { return false }
        return url == pinned || ProcessInfo.processInfo.environment[DaemonLauncher.binaryOverrideKey] == url.path
    }

    /// `cmux-tui/target/hosted/<pinned commit>/cmux-tui`, fetched when
    /// missing; nil when the pin is absent or the fetch failed (offline).
    static let pinned: URL? = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let pin = try? String(contentsOf: root.appendingPathComponent("scripts/cmux-next/cmux-tui.pin"), encoding: .utf8),
              let commit = pin.split(separator: "\n").first(where: { $0.hasPrefix("commit=") })?.dropFirst("commit=".count) else {
            return nil
        }
        let binary = root.appendingPathComponent("cmux-tui/target/hosted/\(commit)/cmux-tui")
        if !FileManager.default.isExecutableFile(atPath: binary.path) { fetchPinned(root: root) }
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
    }()

    /// Runs `pin-cmux-tui.sh fetch` (public URL, no credentials; it keeps
    /// the download only when its sha256 matches the pin).
    private static func fetchPinned(root: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/cmux-next/pin-cmux-tui.sh").path, "fetch"]
        process.standardOutput = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private static func locate() -> URL? {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment[DaemonLauncher.binaryOverrideKey],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        if let pinned { return pinned }
        let cache = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/cmux/cmux-tui-client")
        let slice = "cmux-tui-\(machineArch())-apple-darwin"
        let candidates = ((try? fileManager.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .map { $0.appendingPathComponent(slice) }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { modified($0) > modified($1) }
        guard let newest = candidates.first else { return nil }
        let copy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cnd-bin-\(ProcessInfo.processInfo.processIdentifier)/cmux-tui")
        try? fileManager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: copy)
        guard (try? fileManager.copyItem(at: newest, to: copy)) != nil else { return nil }
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        return copy
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func machineArch() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return machine == "arm64" ? "aarch64" : machine
    }
}

@Suite(.enabled(if: RealBinary.url != nil, "no cmux-tui binary available"), .timeLimit(.minutes(2)), .liveDaemon)
struct IntegrationTests {
    @Test func ensureCreateAttachEchoShutdown() async throws {
        let binary = try #require(RealBinary.url)
        let root = URL(fileURLWithPath: "/tmp/cnd-it-\(UUID().uuidString.prefix(8).lowercased())")
        let session = "cnd-it-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(at: root) }

        let base = ProcessInfo.processInfo.environment
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { LoginEnvironment.shared.daemonEnvironment(login: nil, base: base, overrides: [:]) }
        )
        let ensured = try await launcher.ensure()
        #expect(ensured.session == session)
        let connection = DaemonConnection(endpointProvider: launcher.endpointProvider)
        do {
            let identity = try await connection.start()
            #expect(identity.session == session)
            #expect(await launcher.isStale(identity) == false)

            // The store mirrors the tree through the real event stream.
            let store = await DaemonStore()
            let storeTask = Task { await store.run(connection: connection) }
            defer { storeTask.cancel() }

            let workspace = try await connection.createWorkspace(name: "it")
            let terminal = try await connection.createTerminal(in: workspace.key, cwd: root.path, size: CellSize(cols: 80, rows: 24))
            let surface = try #require(terminal.surface)
            try await store.waitUntil("store sees the new tab") { store.tab(surface: surface) != nil }
            let resourceID = await store.tab(surface: surface)?.terminalResourceID
            #expect(await store.workspace(key: workspace.key)?.name == "it")

            let attachment = try await TerminalAttachment.attach(
                endpoint: ensured.endpoint,
                target: .init(surface: surface, terminalResourceID: resourceID, generation: identity.generation),
                size: CellSize(cols: 80, rows: 24),
                claimGeometry: true
            )
            var iterator = attachment.events.makeAsyncIterator()
            guard case .replay(let replay)? = await iterator.next() else {
                Issue.record("attach did not start with a replay")
                throw DaemonError.malformedResponse("no replay")
            }
            #expect(replay.cols == 80)

            // `$((40+2))` so the expected text never appears in the typed echo.
            await attachment.write(Data("echo hi-$((40+2))\r".utf8))
            // Closing the stream is the timeout: a watchdog detaches after 20 s.
            let watchdog = Task {
                try await Task.sleep(for: .seconds(20))
                await attachment.detach()
            }
            var output = Data()
            var found = false
            while let event = await iterator.next() {
                if case .output(let data, _) = event {
                    output.append(data)
                    if String(decoding: output, as: UTF8.self).contains("hi-42") {
                        found = true
                        break
                    }
                }
            }
            watchdog.cancel()
            #expect(found, "output: \(String(decoding: output, as: UTF8.self))")

            await attachment.resize(cols: 100, rows: 30, pixelWidth: 0, pixelHeight: 0)
            try await store.waitUntil("resize reaches the tree") { store.tab(surface: surface)?.size == CellSize(cols: 100, rows: 30) }
            await attachment.detach()

            // Window state round-trips through the personal projection.
            let windows = WindowStateStore(connection: connection, subject: "it-windows")
            #expect(try await windows.load().windows.isEmpty)
            try await windows.save(window: WindowRecord(id: "w1", workspaceKey: workspace.key,
                                                        frame: WindowFrame(x: 1, y: 2, width: 3, height: 4)))
            let reloaded = WindowStateStore(connection: connection, subject: "it-windows")
            #expect(try await reloaded.load().windows.first?.workspaceKey == workspace.key)
            try await reloaded.save(window: WindowRecord(id: "w2"))
            // The first store's revision is stale now; update reloads and retries.
            try await windows.save(window: WindowRecord(id: "w3"))
            #expect(Set(try await reloaded.load().windows.map(\.id)) == ["w1", "w2", "w3"])

            // Tab drag: move the tab into a new workspace (fallback path on
            // daemons without tab-to-new-workspace).
            _ = try await connection.moveTabToNewWorkspace(surface, transaction: .generate())
            try await store.waitUntil("tab left the old workspace") {
                let old = store.workspace(key: workspace.key)
                return old?.screens.allSatisfy { $0.panes.allSatisfy { $0.tabs.isEmpty } } ?? true
            }
        } catch {
            await BranchDaemonHarness.shutDown(connection)
            throw error
        }
        await BranchDaemonHarness.shutDown(connection)
    }

    /// A Finder launch hands the app launchd's minimal PATH. The launcher
    /// starts the daemon with the login-shell env and the connection sends
    /// the same env with each terminal, so shells in daemon terminals see
    /// the user's PATH.
    ///
    /// The login env is injected (`LauncherTests` covers the real capture),
    /// and its shell is `/bin/sh`, which reads no rc file here. A zsh would
    /// read the runner's `~/.zshenv`, which can set PATH outright (the
    /// cmuxs-mac-mini-3 runner's does), and print that instead of the PATH
    /// the daemon gave it. The `HOME` below has such a `.zshenv`.
    @Test func finderLaunchedDaemonGivesTerminalsTheLoginPath() async throws {
        let binary = try #require(RealBinary.url)
        let root = URL(fileURLWithPath: "/tmp/cnd-it-\(UUID().uuidString.prefix(8).lowercased())")
        let session = "cnd-it-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(at: root) }
        let process = ProcessInfo.processInfo.environment
        var finder: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh"]
        for key in ["USER", "LOGNAME", "TMPDIR"] { finder[key] = process[key] }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\n".utf8)
            .write(to: home.appendingPathComponent(".zshenv"))
        finder["HOME"] = home.path
        // The first entry exists only in the login env, so seeing it proves
        // the terminal got that env rather than the Finder launch's.
        let loginPath = "\(root.appendingPathComponent("login-bin").path):/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let login = ["PATH": loginPath, "SHELL": "/bin/sh", "HOME": home.path]
        let environment = LoginEnvironment.shared.daemonEnvironment(login: login, base: finder, overrides: [:])
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { environment })
        let ensured = try await launcher.ensure()
        // The app's provider, fed the same login env as the launcher (the
        // default one reads the process-wide capture of the test runner's env).
        let connection = DaemonConnection(
            configuration: .init(terminalEnvironment: TerminalEnvironment.instance.shared(base: finder, login: { login })),
            endpointProvider: launcher.endpointProvider)
        do {
            let identity = try await connection.start()
            let workspace = try await connection.createWorkspace(name: "path")
            let terminal = try await connection.createTerminal(in: workspace.key, cwd: root.path, size: CellSize(cols: 200, rows: 24))
            let attachment = try await TerminalAttachment.attach(
                endpoint: ensured.endpoint,
                target: .init(surface: try #require(terminal.surface), generation: identity.generation),
                size: CellSize(cols: 200, rows: 24), claimGeometry: true)
            let watchdog = Task {
                try await Task.sleep(for: .seconds(20))
                await attachment.detach()
            }
            await attachment.write(Data("printf 'P%s=[%s]\\n' X \"$PATH\"\r".utf8))
            var output = ""
            var seen: String?
            for await event in attachment.events {
                guard case .output(let data, _) = event else { continue }
                output += String(decoding: data, as: UTF8.self)
                if let start = output.range(of: "PX=["), let end = output[start.upperBound...].range(of: "]") {
                    seen = String(output[start.upperBound..<end.lowerBound])
                    break
                }
            }
            watchdog.cancel()
            await attachment.detach()
            // The daemon may add its own shims; every login entry must be there.
            let entries = Set((seen ?? "").split(separator: ":").map(String.init))
            let missing = loginPath.split(separator: ":").map(String.init).filter { !entries.contains($0) }
            #expect(seen != nil)
            #expect(missing.isEmpty, "missing from terminal PATH: \(missing); login PATH: \(loginPath); seen: \(seen ?? "<none>")")
        } catch {
            await BranchDaemonHarness.shutDown(connection)
            throw error
        }
        await BranchDaemonHarness.shutDown(connection)
    }
}
