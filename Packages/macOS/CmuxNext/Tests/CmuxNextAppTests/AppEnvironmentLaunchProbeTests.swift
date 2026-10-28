import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// p08-startup 033: `main` makes the launch's environment with no file call; Ghostty's lookups (resources,
/// CLI helper, terminfo) are one launch read every shell's env awaits, and the chat stores reach the panes by init.
@Suite("App environment with no file call on main", .serialized)
@MainActor
struct AppEnvironmentLaunchProbeTests {
    /// What a lane found on a Mac with Ghostty's terminfo installed and this build's helper.
    nonisolated static let found = GhosttyLaunchProbe(resources: "/probe/Resources/ghostty", binary: "/probe/Resources/bin/ghostty")
    static let work = BackgroundWork(label: "test.ghostty-probe")
    nonisolated static let login: @Sendable () async -> [String: String]? = { ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"] }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// Before the change, `current` made up to 14 terminfo stats and a shell-integration check on main.
    @Test("Making the launch's environment calls no file on the main thread")
    func makingTheEnvironmentCallsNoFile() async {
        let table = BlockingViolationTable(mode: .record)
        BlockingViolationTable.$scoped.withValue(table) {
            _ = AppEnvironment.current([:])
            _ = AppEnvironment.current([:], ghosttyResources: "/probe/Resources/ghostty")
        }
        await table.flush()
        let onMain = table.sites.filter { $0.context == .main }.map(\.location)
        #expect(onMain.isEmpty, "AppEnvironment.current called files on the main thread: \(onMain)")
    }
    #endif

    @Test("A shell's env carries what the launch read found: helper and resources")
    func aShellsEnvCarriesTheLaunchRead() async {
        var environment = AppEnvironment.current([:])
        environment.ghosttyProbe = GhosttyLaunchProbe.start(on: Self.work) { Self.found }
        let env = await environment.terminalEnvironmentProvider(login: Self.login, settings: { nil })()
        #expect(env["GHOSTTY_BIN"] == "/probe/Resources/bin/ghostty")
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["GHOSTTY_RESOURCES_DIR"] == "/probe/Resources/ghostty")
        // The daemon's own environment gets the same keys over its overrides.
        #expect(await environment.resolvedTerminalEnvironment()?() == ["GHOSTTY_RESOURCES_DIR": "/probe/Resources/ghostty"])
    }

    /// `terminal.term` (or the Ghostty config's `term`) names another `TERM`: shells get it when its entry is
    /// installed, checked on the files lane, and the standard one with a log line when it is not.
    @Test("An asked-for TERM is used only when its terminfo entry is installed")
    func anAskedForTermNeedsItsEntry() async {
        let installed: Set = ["/home/me/.terminfo/78/xterm-ghostty"]
        var environment = AppEnvironment.current([:])
        environment.terminfo = TerminfoLookup(work: Self.work, home: "/home/me", fileExists: { installed.contains($0) })
        let ghostty = await environment.terminalEnvironmentProvider(login: Self.login, settings: { nil },
                                                                    term: { TerminalTermChoice(setting: "xterm-ghostty") })()
        #expect(ghostty["TERM"] == "xterm-ghostty")
        #expect(ghostty["TERM_PROGRAM"] == "ghostty")
        let missing = await environment.terminalEnvironmentProvider(login: Self.login, settings: { nil },
                                                                    term: { TerminalTermChoice(setting: "wezterm") })()
        #expect(missing["TERM"] == "xterm-256color")
        let invalid = await environment.terminalEnvironmentProvider(login: Self.login, settings: { nil },
                                                                    term: { TerminalTermChoice(setting: "../../etc/x") })()
        #expect(invalid["TERM"] == "xterm-256color")
    }

    /// A `term` the person set in their Ghostty config is honored; cmux.json's `terminal.term` wins over it.
    @Test("The Ghostty config's explicit term applies unless terminal.term is set")
    func theGhosttyConfigsTermApplies() async {
        let installed: Set = ["/usr/share/terminfo/x/xterm-ghostty", "/usr/share/terminfo/s/screen-256color"]
        var environment = AppEnvironment.current([:])
        environment.terminfo = TerminfoLookup(work: Self.work, home: "/home/me", fileExists: { installed.contains($0) })
        let fromConfig = await environment.terminalEnvironmentProvider(login: Self.login, settings: { nil },
                                                                       term: { TerminalTermChoice(ghosttyConfig: "xterm-ghostty") })()
        #expect(fromConfig["TERM"] == "xterm-ghostty")
        let settingWins = await environment.terminalEnvironmentProvider(
            login: Self.login, settings: { nil },
            term: { TerminalTermChoice(setting: "screen-256color", ghosttyConfig: "xterm-ghostty") })()
        #expect(settingWins["TERM"] == "screen-256color")
        let standardWins = await environment.terminalEnvironmentProvider(
            login: Self.login, settings: { nil },
            term: { TerminalTermChoice(setting: "xterm-256color", ghosttyConfig: "xterm-ghostty") })()
        #expect(standardWins["TERM"] == "xterm-256color")
    }

    /// Lawrence 2026-10-28: "default echo $TERM should not use the ghostty one but should use the standard one
    /// that every tool recognizes, for all cmux". On a Mac with Ghostty's terminfo installed (Ghostty.app), new
    /// terminals and the daemon's own environment got xterm-ghostty, which ssh targets, VMs and containers lack.
    @Test("A Ghostty terminfo on disk keeps the standard TERM for shells and the daemon")
    func aGhosttyTerminfoOnDiskKeepsTheStandardTerm() async {
        var environment = AppEnvironment.current([:])
        let probe = GhosttyLaunchProbe.look(environment: [:], fileExists: { $0.hasSuffix("/xterm-ghostty") }, isExecutable: { _ in false })
        environment.ghosttyProbe = GhosttyLaunchProbe.start(on: Self.work) { probe }
        let env = await environment.terminalEnvironmentProvider(login: Self.login, settings: { nil })()
        #expect(env["TERM"] == "xterm-256color")
        // Programs still detect Ghostty's features without its TERM.
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM"] == "ghostty")
        #expect(environment.terminalEnvironment["TERM"] == "xterm-256color")
        let daemonKeys = await environment.resolvedTerminalEnvironment()?() ?? [:]
        #expect(daemonKeys["TERM"] == nil || daemonKeys["TERM"] == "xterm-256color")
    }

    @Test("Without a launch read a shell gets xterm-256color and no Ghostty folder or helper")
    func withoutALaunchRead() async {
        let environment = AppEnvironment.current([:])
        let env = await environment.terminalEnvironmentProvider(login: Self.login, settings: { nil })()
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["GHOSTTY_BIN"] == nil)
        #expect(env["GHOSTTY_RESOURCES_DIR"] == nil)
        #expect(environment.resolvedTerminalEnvironment() == nil)
    }

    /// A quit that begins before the read starts still runs it, so no shell's env waits forever.
    @Test("A read posted as quit begins still finishes", .timeLimit(.minutes(1)))
    func aReadAtQuitStillFinishes() async {
        let work = BackgroundWork(label: "test.ghostty-probe-quit")
        work.beginShutdown()
        let probe = GhosttyLaunchProbe.start(on: work) { Self.found }
        #expect(await probe.finished() == Self.found)
        await work.shutdown()
    }

    @Test("The probe makes its checks through the given seams")
    func theProbeUsesItsSeams() {
        let inherited = "/inherited/ghostty"
        let present: Set = [inherited + "/themes", "/home/me/.terminfo/78/xterm-ghostty"]
        let probe = GhosttyLaunchProbe.look(environment: ["GHOSTTY_RESOURCES_DIR": inherited],
                                            fileExists: { present.contains($0) }, isExecutable: { _ in false })
        #expect(probe == GhosttyLaunchProbe(resources: inherited, binary: nil))
        let none = GhosttyLaunchProbe.look(environment: [:], fileExists: { _ in false }, isExecutable: { _ in false })
        #expect(none.terminalEnvironment.isEmpty)
    }

    @Test("The app integrates the shell only from its bundled resources")
    func shellIntegrationFollowsTheBundle() {
        #expect(AppEnvironment.current([:], ghosttyResources: "/probe/Resources/ghostty").resolvesShellIntegration)
        #expect(!AppEnvironment.current([:], ghosttyResources: nil).resolvesShellIntegration)
        let app = URL(fileURLWithPath: "/Applications/cmux NEXT.app", isDirectory: true)
        #expect(GhosttyRuntime.bundledResourcesDirectory(bundleURL: app, resourceURL: app.appending(path: "Contents/Resources"))
            == "/Applications/cmux NEXT.app/Contents/Resources/ghostty")
        let tests = URL(fileURLWithPath: "/tmp/CmuxNextPackageTests.xctest", isDirectory: true)
        #expect(GhosttyRuntime.bundledResourcesDirectory(bundleURL: tests, resourceURL: tests) == nil)
    }

    /// Services whose launch snapshot is in a temporary folder, as the app's is in its state folder.
    private static func services(state: URL) -> AppServices {
        _ = NSApplication.shared
        var environment = AppEnvironment.current([:])
        environment.sidebarSnapshotFile = SidebarSnapshotFile(url: state.appending(path: SidebarSnapshotFile.fileName))
        return AppServices(environment: environment)
    }

    private static func state() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "chat-stores-033-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("The agent tabs keep each chat's place and chips beside the launch snapshot")
    func theAgentTabsKeepTheStoresBesideTheSnapshot() throws {
        let state = try Self.state()
        defer { try? FileManager.default.removeItem(at: state) }
        let stores = Self.services(state: state).agentTabs.chatStores
        #expect(stores.scrollAnchors?.file?.path == state.appending(path: AgentPaneScrollAnchors.fileName).path)
        let chips = try #require(stores.draftAttachments?.folder(for: "s-1"))
        #expect(chips.path.hasPrefix(state.appending(path: AgentPaneDraftAttachments.directoryName).path + "/"))
    }

    @Test("A chat's place written through one pane's page is read through another's")
    func onePanesWriteIsAnothersRead() async throws {
        let state = try Self.state()
        defer { try? FileManager.default.removeItem(at: state) }
        let stores = Self.services(state: state).agentTabs.chatStores
        let context = PageCallContext(page: PageDescriptor.agent.id)
        let (first, second) = (AgentPageProvider(chatStores: stores, mainWork: AgentPaneMainThread.standalone().mainWork) { _ in nil }, AgentPageProvider(chatStores: stores, mainWork: AgentPaneMainThread.standalone().mainWork) { _ in nil })
        _ = try await first.call(AgentPageOps.namespace + "chat.scrollAnchor",
                                 params: .object(["sessionId": .string("s-1"), "rowId": .string("user-7"), "offset": .number(12)]),
                                 context: context)
        let place = try await second.call(AgentPageOps.namespace + "chat.scrollAnchor.get",
                                          params: .object(["sessionId": .string("s-1")]), context: context)
        #expect(place == .object(["rowId": .string("user-7"), "offset": .number(12)]))
    }
}
