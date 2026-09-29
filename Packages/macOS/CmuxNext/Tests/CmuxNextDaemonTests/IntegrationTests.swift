import Foundation
import Testing
@testable import CmuxNextDaemon

/// Finds a real cmux-tui: `CMUX_NEXT_TUI_BIN`, else the newest client that
/// scripts/install-cmux-tui-client.sh cached, else a hosted verification
/// artifact under cmux-tui/target/hosted. Cached slices are not executable,
/// so they are copied into a temp dir first.
enum RealBinary {
    static let url: URL? = locate()

    private static func locate() -> URL? {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment[DaemonLauncher.binaryOverrideKey],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
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

@Suite(.enabled(if: RealBinary.url != nil, "no cmux-tui binary available"), .timeLimit(.minutes(2)))
struct IntegrationTests {
    @Test func ensureCreateAttachEchoShutdown() async throws {
        let binary = try #require(RealBinary.url)
        let root = URL(fileURLWithPath: "/tmp/cnd-it-\(UUID().uuidString.prefix(8).lowercased())")
        let session = "cnd-it-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(at: root) }

        let base = ProcessInfo.processInfo.environment
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { LoginEnvironment.daemonEnvironment(login: nil, base: base, overrides: [:]) }
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
            try await waitUntil("store sees the new tab") { await store.tab(surface: surface) != nil }
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
            try await waitUntil("resize reaches the tree") { await store.tab(surface: surface)?.size == CellSize(cols: 100, rows: 30) }
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
            _ = try await connection.tabToNewWorkspace(surface, transaction: .generate())
            try await waitUntil("tab left the old workspace") {
                await MainActor.run {
                    let old = store.workspace(key: workspace.key)
                    return old?.screens.allSatisfy { $0.panes.allSatisfy { $0.tabs.isEmpty } } ?? true
                }
            }
        } catch {
            try? await connection.shutdownDaemon()
            await connection.close()
            throw error
        }
        try await connection.shutdownDaemon()
        await connection.close()
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw DaemonError.timedOut(what)
    }
}
