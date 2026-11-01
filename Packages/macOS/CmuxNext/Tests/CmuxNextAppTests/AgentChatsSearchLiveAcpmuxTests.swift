import AppKit
import CmuxNextActions
@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
@testable import CmuxNextPalette
import Foundation
import Testing

/// The tree's acpmux for the live chat-search suite: the one beside the lane's cmux-tui
/// (`CMUX_NEXT_TUI_TREE_PATH`, which a lane may take from the newest published tree when this head
/// changes no cmux-tui input), else `pin-cmux-tui.sh acpmux-path`.
nonisolated enum ChatsSearchTreeAcpmux {
    static let url: URL? = {
        if let tree = ProcessInfo.processInfo.environment["CMUX_NEXT_TUI_TREE_PATH"], !tree.isEmpty {
            let beside = URL(fileURLWithPath: tree).deletingLastPathComponent().appendingPathComponent("acpmux")
            if FileManager.default.isExecutableFile(atPath: beside.path) { return beside }
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/cmux-next/pin-cmux-tui.sh").path, "acpmux-path"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }()
}

/// FC-3 (fuzz catalog, 2026-11-01): after #28090 Search asks acpmux for the chats of each query, and no
/// bench or probe ever saw a chat row from a real acpmux. This is what the person sees, end to end: a real
/// acpmux daemon started the way the app starts it, whose chat index reads 3,000 Claude Code chats from the
/// home folder; the app's chat feed on its socket; and Search with the agent chats contributed as the App
/// contributes them, with the palette's real choice history. Typing a word of one chat's title shows that
/// chat under Agent Chats, also when the word is typed before the index has started.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: ChatsSearchTreeAcpmux.url != nil, "needs the same-tree acpmux"))
struct AgentChatsSearchLiveAcpmuxTests {
    static let chats = 3000
    static let zebra = 1234
    static let quokka = 77

    static func session(_ i: Int) -> String { String(format: "00000000-0000-4000-8000-%012ld", i) }
    static func rowID(_ i: Int) -> String { "chat:claude-code:\(session(i))" }

    /// The first prompt of chat `i` (its title in the index).
    static func title(_ i: Int) -> String {
        switch i {
        case zebra: "Zebra migration plan"
        case quokka: "Quokka habitat survey"
        default: "Idle cost chat \(i): tidy the build scripts"
        }
    }

    /// `chats` Claude Code transcripts in `<home>/.claude/projects` (a default root of the chat index), one
    /// second apart a day ago, each the one user record Claude Code writes first.
    static func seed(home: URL) throws {
        let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let dayAgo = Date().addingTimeInterval(-86_400)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for i in 0..<chats {
            let folder = projects.appendingPathComponent("-work-p\(i % 40)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let at = dayAgo.addingTimeInterval(TimeInterval(i))
            let record: [String: Any] = ["type": "user", "isSidechain": false, "cwd": "/work/p\(i % 40)", "sessionId": session(i),
                                         "timestamp": stamp.string(from: at), "message": ["role": "user", "content": title(i)]]
            var line = try JSONSerialization.data(withJSONObject: record)
            line.append(0x0A)
            let file = folder.appendingPathComponent("\(session(i)).jsonl")
            try line.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: file.path)
        }
    }

    /// The real path of `url` (`/tmp` is a symlink on macOS; the person's home is a real folder).
    static func real(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Search with the agent chats as the App contributes them (PaletteSourcesBridge,
    /// `AgentChatsPalettePage.init(services:)`): over the feed's windows, with the palette's own choice history.
    static func palette(windows: AcpmuxChatWindows) -> (PaletteController, ActionRegistry) {
        _ = NSApplication.shared
        final class Owner { weak var palette: PaletteController? }
        let owner = Owner()
        var sources = PaletteSources()
        sources.searchContributions = [
            PaletteSearchContribution(id: "agentChats", title: AgentChatsPalettePage.title, order: 30, searchesChats: true) {
                AgentChatsPalettePage(windows: windows,
                                      history: { [owner] query in await owner.palette?.model.rankerHistory(keyPrefix: "chat:", query: query) },
                                      open: { _ in }).page()
            },
        ]
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: sources, frecencyPersistence: nil)
        owner.palette = palette
        palette.bindRegistryActions()
        return (palette, registry)
    }

    /// Waits until the rows on screen hold `id`, or `limit` passes; whether they did.
    static func shows(_ id: String, in palette: PaletteController, within limit: Duration) async -> Bool {
        await shows(in: palette, within: limit) { $0.item.id == id }
    }

    /// Waits until a row on screen passes `test`, or `limit` passes; whether one did.
    static func shows(in palette: PaletteController, within limit: Duration, _ test: (PaletteRow) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if palette.model.rows.contains(where: test) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return palette.model.rows.contains(where: test)
    }

    @Test func searchShowsTheChatWhoseTitleHoldsTheTypedWord() async throws {
        let binary = try #require(ChatsSearchTreeAcpmux.url)
        let made = URL(fileURLWithPath: "/tmp/fc3-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        let root = Self.real(made)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let acpmuxHome = root.appendingPathComponent("acpmux", isDirectory: true)
        let bin = root.appendingPathComponent("app/bin", isDirectory: true)
        let socket = acpmuxHome.appendingPathComponent("s.sock").path
        for folder in [home, acpmuxHome, bin] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try FileManager.default.copyItem(at: binary, to: bin.appendingPathComponent("acpmux"))
        try Self.seed(home: home)
        // The daemon's home folder is the seeded one; no harness home of the runner's account is read.
        var launch = ["HOME": home.path]
        for key in ["CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "CODEX_HOME", "GEMINI_CLI_HOME", "QWEN_RUNTIME_DIR",
                    "PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR", "CODING_AGENT_DIR", "CURSOR_DATA_DIR", "CURSOR_CONFIG_DIR"] {
            launch[key] = ""
        }
        let environment = try #require(AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: bin,
                                                                 environment: ["ACPMUX_HOME": acpmuxHome.path, "ACPMUX_SOCKET": socket],
                                                                 launchEnvironment: launch, executableOverride: nil))

        // The app's launch: acpmux starts, the chat feed connects, and the person opens Search and types at once
        // (the index may not have started yet).
        let started = ContinuousClock.now
        try await AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: environment).prewarm()
        let feed = ChatsFeed(socketPath: environment.socketPath)
        feed.keepCurrent()
        let (palette, registry) = Self.palette(windows: feed.windows)
        var report: [String] = []
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.setQuery("zebra"))
        let zebra = await Self.shows(Self.rowID(Self.zebra), in: palette, within: .seconds(90))
        report.append("zebra: \(zebra) after \(ContinuousClock.now - started)")
        #expect(zebra, "Search shows the chat titled \"\(Self.title(Self.zebra))\" for \"zebra\"")
        let row = palette.model.rows.first { $0.item.id == Self.rowID(Self.zebra) }
        #expect(row?.item.section.title == AgentChatsPalettePage.title, "the chat shows under Agent Chats")
        #expect(row?.item.title == Self.title(Self.zebra))
        var seen = zebra

        // The index is ready now: the next word's chat shows within a short bound, and the last word's goes.
        let typed = ContinuousClock.now
        palette.model.send(.setQuery("quokka"))
        let quokka = await Self.shows(Self.rowID(Self.quokka), in: palette, within: .seconds(5))
        report.append("quokka: \(quokka) after \(ContinuousClock.now - typed)")
        #expect(quokka, "Search shows the chat titled \"\(Self.title(Self.quokka))\" for \"quokka\"")
        #expect(!palette.model.rows.contains { $0.item.id == Self.rowID(Self.zebra) }, "the last query's chat is gone")
        seen = seen && quokka

        // The bench's word matches every other chat: Search shows the best of them and says that more match
        // (its cut's more row, or the page's own "best 200 of N" notice when nothing is cut).
        palette.model.send(.setQuery("idle"))
        let more = await Self.shows(in: palette, within: .seconds(5)) { ["agentChats.moreInSearch", "agentChats.more"].contains($0.item.id) }
        let shown = palette.model.rows.filter { $0.item.id.hasPrefix("chat:claude-code:") }.count
        report.append("idle: \(shown) chat rows, more row \(more)")
        #expect(shown >= PaletteContributedAnswers.searchShare, "Search shows the best chats for \"idle\"")
        #expect(more, "and says that more chats match")
        seen = seen && more

        print("FC-3 live chats search: " + report.joined(separator: "; "))
        if !seen {
            let log = (try? String(contentsOf: acpmuxHome.appendingPathComponent("daemon.log"), encoding: .utf8))
                .map { $0.split(separator: "\n").suffix(40).joined(separator: "\n") } ?? "no daemon.log"
            let window = feed.windows.window(AgentChatsPalettePage.window)
            print("FC-3 feed: connected \(feed.windows.isConnected), refused \(feed.windows.isRefused(AgentChatsPalettePage.window)), "
                + "window rows \(window.rows.count), total \(String(describing: window.total))\n"
                + "rows: \(palette.model.rows.map(\.item.id).prefix(30))\n--- daemon.log\n\(log)")
        }
        palette.hide()
        _ = try? await AcpmuxStatusClient.shutdown(socketPath: socket, home: acpmuxHome, deadline: .seconds(10))
        withExtendedLifetime(feed) {}
    }
}
