import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTabs
import Foundation
import Testing

/// Lawrence 2026-10-28 ("spamming cmd w needs to work ... very fast must work perfectly"; input-principles.md,
/// hold-shortcuts-ux.md 3, audit-findings-1.md A2/A4/A5): N Cmd-W presses close N tabs, each in the press's own
/// turn, from the local model as the presses before left it; a confirmation is asked in the first press's turn and
/// later presses go to it; key repeat never closes the last tab of a pane (a new press does). Runs the app's Close
/// Tab, as the key router dispatches it, against a same-tree cmux-tui daemon whose terminals run zsh with the
/// daemon's shell integration (so the daemon pushes each terminal's prompt and running-command state).
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdWSpamTests {
    /// A2: with `app.warnBeforeClosingTab` off, each press closes one terminal tab in its own turn; the toast's
    /// process read never leaves the tab targetable for the next press (before: 3 presses closed 1 tab).
    @Test func eachPressClosesATerminalTabInItsOwnTurnWithTheWarningOff() async throws {
        try await Self.withZshApp(settings: #"{"app":{"warnBeforeClosingTab":false}}"#) { services, connection in
            let (pane, ids) = try await Self.terminalTabs(4, services, connection, atPrompt: false)
            pane.select(TabID(ids[0]))
            for index in 0..<3 {
                #expect(Self.press(services, repeat: false))
                #expect(pane.orderedIDs.count == 4 - index - 1, "press \(index + 1): the strip still holds \(pane.orderedIDs.map(\.rawValue)) in its turn")
            }
            try await PinnedPageTests.until({ ids.prefix(3).allSatisfy { services.daemon.store.tab(id: $0) == nil } },
                                            report: { "the daemon still has \(ids.filter { services.daemon.store.tab(id: $0) != nil })" })
            #expect(services.daemon.store.tab(id: ids[3]) != nil, "a fourth tab closed")
        }
    }

    /// Default settings (the warning on): idle terminals at their prompt close in the press's own turn, N presses
    /// N tabs, with no process read in between (the daemon's pushed prompt state says they are idle).
    @Test func eachPressClosesAnIdleTerminalAtItsPromptInItsOwnTurn() async throws {
        try await Self.withZshApp(settings: nil) { services, connection in
            let (pane, ids) = try await Self.terminalTabs(4, services, connection, atPrompt: true)
            pane.select(TabID(ids[0]))
            for index in 0..<3 {
                #expect(Self.press(services, repeat: false))
                #expect(pane.orderedIDs.count == 4 - index - 1,
                        "press \(index + 1): an idle terminal did not leave the strip in its turn: \(pane.orderedIDs.map(\.rawValue))")
            }
            #expect(pane.stripModel.selectedID?.rawValue == ids[3])
            try await PinnedPageTests.until({ ids.prefix(3).allSatisfy { services.daemon.store.tab(id: $0) == nil } })
            #expect(services.daemon.store.tab(id: ids[3]) != nil, "a fourth tab closed")
        }
    }

    /// A4: the selected terminal runs a program. Press 1 asks, in its own turn; presses 2 and 3 (and the held key's
    /// repeats) go to that question: the idle neighbours stay open, and one question shows.
    @Test func aRunningProgramAsksInThePressTurnAndLaterPressesGoToTheQuestion() async throws {
        try await Self.withZshApp(settings: nil) { services, connection in
            let (pane, ids) = try await Self.terminalTabs(3, services, connection, atPrompt: true)
            let busy = try #require(services.daemon.store.tab(id: ids[0]))
            try await connection.send(busy.surface, text: "sleep 60\r")
            try await PinnedPageTests.until({ services.daemon.store.tab(id: ids[0])?.commandSinceMs != nil },
                                            report: { "the daemon never reported the running command" })
            pane.select(TabID(ids[0]))
            let before = Set(CmuxDialogCenter.shared.records.map(\.id))
            func questions() -> [CmuxDialogCenter.Record] { CmuxDialogCenter.shared.records.filter { !before.contains($0.id) } }
            #expect(Self.press(services, repeat: false))
            #expect(questions().count == 1, "press 1 did not ask in its own turn: \(questions().map(\.spec.title))")
            #expect(Self.press(services, repeat: false))
            #expect(Self.press(services, repeat: true))
            #expect(Self.press(services, repeat: false))
            try await Task.sleep(for: .milliseconds(1500))
            #expect(ids.allSatisfy { services.daemon.store.tab(id: $0) != nil }, "a press behind the question closed a tab")
            #expect(pane.orderedIDs.count == 3, "the strip lost a tab behind the question: \(pane.orderedIDs)")
            #expect(questions().count == 1, "\(questions().count) questions for one close")
            for question in questions() { CmuxDialogCenter.shared.press(question.id, button: "cancel") }
        }
    }

    /// Review 1 of cp/spam-cmdw: an interactive program (less, vim, ssh: the daemon's `in_use`, which has no
    /// running-command time) asks too, in press 1's turn; the presses behind it close no idle neighbour.
    @Test func anInteractiveProgramAsksInThePressTurnToo() async throws {
        try await Self.withZshApp(settings: nil) { services, connection in
            let (pane, ids) = try await Self.terminalTabs(3, services, connection, atPrompt: true)
            let busy = try #require(services.daemon.store.tab(id: ids[0]))
            try await connection.send(busy.surface, text: "less /etc/hosts\r")
            try await PinnedPageTests.until({ services.daemon.store.tab(id: ids[0]).map { $0.commandInUse || $0.commandSinceMs != nil } == true },
                                            report: { "the daemon never reported less as a running command" })
            pane.select(TabID(ids[0]))
            let before = Set(CmuxDialogCenter.shared.records.map(\.id))
            func questions() -> [CmuxDialogCenter.Record] { CmuxDialogCenter.shared.records.filter { !before.contains($0.id) } }
            #expect(Self.press(services, repeat: false))
            #expect(questions().count == 1, "press 1 did not ask in its own turn for less")
            #expect(Self.press(services, repeat: false))
            try await Task.sleep(for: .milliseconds(1500))
            #expect(ids.allSatisfy { services.daemon.store.tab(id: $0) != nil }, "a press behind the question closed a tab")
            for question in questions() { CmuxDialogCenter.shared.press(question.id, button: "cancel") }
        }
    }

    /// Review 1 of cp/spam-cmdw: terminals with no shell state (sh, no integration) are read before the close asks.
    /// Presses made during that read wait for it, in order: with a running program they go to the question and close
    /// no idle neighbour; with none they each close the next tab.
    @Test func pressesDuringAReadWaitForItAndGoToTheQuestion() async throws {
        try await Self.withZshApp(settings: nil, shell: "/bin/sh") { services, connection in
            let (pane, ids) = try await Self.terminalTabs(3, services, connection, atPrompt: false)
            let busy = try #require(services.daemon.store.tab(id: ids[0]))
            try await connection.send(busy.surface, text: "sleep 60\r")
            try await Task.sleep(for: .milliseconds(500))
            try #require(TabCloseGuard.pushedState(busy) == .unknown, "sh reported shell state")
            pane.select(TabID(ids[0]))
            let before = Set(CmuxDialogCenter.shared.records.map(\.id))
            func questions() -> [CmuxDialogCenter.Record] { CmuxDialogCenter.shared.records.filter { !before.contains($0.id) } }
            for _ in 0..<3 { #expect(Self.press(services, repeat: false)) }
            try await PinnedPageTests.until({ !questions().isEmpty }, report: { "no question for sleep" })
            try await Task.sleep(for: .milliseconds(800))
            #expect(ids.allSatisfy { services.daemon.store.tab(id: $0) != nil }, "a press during the read closed an idle neighbour")
            #expect(questions().count == 1, "\(questions().count) questions for one close")
            for question in questions() { CmuxDialogCenter.shared.press(question.id, button: "cancel") }
        }
    }

    /// Review 1 of cp/spam-cmdw: with the warning off, a terminal with no shell state closes in the press's turn, and
    /// the undo toast still shows when it ran a program (the read decides after the close); an idle one shows none.
    @Test func theToastStillShowsForAProgramWhenTheReadDecidesAfterTheClose() async throws {
        try await Self.withZshApp(settings: #"{"app":{"warnBeforeClosingTab":false}}"#, shell: "/bin/sh") { services, connection in
            let (pane, ids) = try await Self.terminalTabs(3, services, connection, atPrompt: false)
            let window = try #require(pane.view.window)
            let busy = try #require(services.daemon.store.tab(id: ids[0]))
            try await connection.send(busy.surface, text: "sleep 60\r")
            try await Task.sleep(for: .milliseconds(500))
            pane.select(TabID(ids[0]))
            #expect(Self.press(services, repeat: false))
            #expect(pane.orderedIDs.count == 2, "the close waited for the read")
            try await PinnedPageTests.until({ CmuxToastCenter.shared.toasts(in: window).contains { $0.id == CloseUndoToasts.toastID } },
                                            report: { "no undo toast for a terminal that ran sleep" })
            let shown = CmuxToastCenter.shared.toasts(in: window).filter { $0.id == CloseUndoToasts.toastID }.count
            // An idle one, after the toast rate limit: no new toast (the open one does not count it).
            services.closedTabs?.undoToasts.now = { .now + .seconds(600) }
            pane.select(TabID(ids[1]))
            #expect(Self.press(services, repeat: false))
            try await Task.sleep(for: .milliseconds(2500))
            #expect(CmuxToastCenter.shared.toasts(in: window).filter { $0.id == CloseUndoToasts.toastID }.count <= shown,
                    "an idle terminal's close showed a toast")
        }
    }

    /// The lead, 2026-10-28: a command typed a moment before the press (its key reached the window, the daemon has not
    /// reported the command yet) must never close unasked: the pushed idle state is stale, so the close reads first.
    @Test func aKeyTypedJustBeforeThePressMakesTheIdleStateUnknown() async throws {
        try await Self.withZshApp(settings: nil) { services, connection in
            let (pane, ids) = try await Self.terminalTabs(2, services, connection, atPrompt: true)
            let tab = try #require(services.daemon.store.tab(id: ids[0]))
            pane.select(TabID(ids[0]))
            #expect(TabCloseGuard.pushedState(tab) == .idle)
            // A typing key into the window, after the app applied the idle state.
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: pane.view.window?.windowNumber ?? 0, context: nil, characters: "s",
                                                   charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
            _ = services.keyRouter.typesIntoFocusedView(key, in: pane.view.window)
            let typed = { (uptime: TimeInterval) in services.keyRouter.typed(in: pane.view.window, after: uptime) }
            #expect(PushedShellState(tab, typedSince: typed) == .unknown, "a key typed after the idle state still read idle")
            #expect(Self.press(services, repeat: false))
            #expect(pane.orderedIDs.count == 2, "the close did not read the terminal first: it closed in the press's turn")
        }
    }

    /// hold-shortcuts-ux.md 3: key repeat never crosses a boundary. A held Cmd-W closes the pane's tabs at the
    /// repeat rate and stops before its last tab; a new physical press closes that one (and the pane).
    @Test func aHeldCmdWStopsBeforeThePanesLastTabAndANewPressClosesIt() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let content = try #require(services.windows.active?.workspaceContent)
            let store = services.daemon.store
            let left = try #require(store.workspaces.first?.screens.first?.panes.first)
            let before = Set(content.panes.keys)
            #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ content.panes.contains { !before.contains($0.key) && !$0.value.pane.tabs.isEmpty
                    && $0.value.pane.tabs.allSatisfy { !ProvisionalTab.isProvisional(surface: $0.surface) } } })
            let right = try #require(content.panes.first { !before.contains($0.key) }?.value)
            let terminal = try #require(right.pane.tabs.first?.surface)
            var pages: [SurfaceID] = []
            for index in 0..<3 {
                pages.append(try await connection.newFrontendBrowserTab(url: "https://example.com/held-\(index)", engine: .webkit,
                                                                       in: right.pane.handle, activate: false).surface)
            }
            try await connection.closeTab(terminal)
            try await PinnedPageTests.until({ pages.allSatisfy { store.tab(surface: $0) != nil } && right.orderedIDs.count == 3 })
            let ids = pages.compactMap { store.tab(surface: $0)?.id }
            right.select(TabID(ids[0]))
            PaneHandlers.focus(right.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === right })

            // The press and four repeats: two tabs close, the last stays (the repeats stop at the boundary).
            _ = Self.press(services, repeat: false)
            for _ in 0..<4 { _ = Self.press(services, repeat: true) }
            #expect(right.orderedIDs.map(\.rawValue) == [ids[2]], "the held key left \(right.orderedIDs.map(\.rawValue)), wanted only the last tab")
            #expect(content.panes[right.layoutPaneID] != nil, "a key repeat closed the pane")
            try await Task.sleep(for: .milliseconds(300))
            #expect(store.tab(id: ids[2]) != nil, "a key repeat closed the pane's last tab")
            #expect(store.pane(left.handle) != nil)

            // A new press closes the last tab, and the pane with it.
            _ = Self.press(services, repeat: false)
            try await PinnedPageTests.until({ store.tab(id: ids[2]) == nil }, report: { "the new press did not close the last tab" })
        }
    }

    // MARK: Helpers

    /// `count` terminal tabs in the first pane; with `atPrompt`, once the daemon reported each one's prompt.
    static func terminalTabs(_ count: Int, _ services: AppServices, _ connection: DaemonConnection,
                             atPrompt: Bool) async throws -> (PaneController, [String]) {
        let store = services.daemon.store
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        // The restore's own terminal leaves first, so the pane holds only the test's tabs.
        let first = model.tabs.map(\.surface)
        var surfaces: [SurfaceID] = []
        for _ in 0..<count { surfaces.append(try await connection.newTab(in: model.handle).surface) }
        for surface in first { try await connection.closeTab(surface) }
        let pane = try #require(services.paneController(for: model))
        try await PinnedPageTests.until({ surfaces.allSatisfy { store.tab(surface: $0) != nil } && pane.orderedIDs.count == count },
                                        report: { "the pane holds \(pane.orderedIDs)" })
        if atPrompt {
            try await PinnedPageTests.until({ surfaces.allSatisfy { store.tab(surface: $0)?.shellIdleSinceMs != nil } },
                                            within: .seconds(30), report: { "the daemon never reported an idle shell (zsh integration, shell_idle)" })
        }
        let ids = surfaces.compactMap { store.tab(surface: $0)?.id }
        let window = try #require(services.windows.active?.workspaceContent)
        PaneHandlers.focus(pane.layoutPaneID, in: window)
        return (pane, ids)
    }

    /// One Cmd-W key-down (or a repeat of it) as the key router dispatches it.
    @discardableResult
    static func press(_ services: AppServices, repeat isRepeat: Bool) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: isRepeat, keyCode: 13)
        let dispatching = services.registry.dispatchingInputEvent
        services.registry.dispatchingInputEvent = { event }
        defer { services.registry.dispatchingInputEvent = dispatching }
        return services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
    }

    /// ``PinnedPageTests/withApp(_:)`` with zsh terminals (the daemon injects its shell integration, so it pushes
    /// each terminal's prompt and running command), an empty home, and `settings` as the cmux.json.
    static func withZshApp(settings json: String?, shell: String = "/bin/zsh", _ body: (AppServices, DaemonConnection) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-cmdw-\(UUID().uuidString.prefix(8))")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = DaemonLauncher(
            work: BackgroundWork(label: "test.daemon-launcher"),
            configuration: .init(binary: binary, session: "cn-cmdw-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": shell, "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        if let json {
            let url = root.appendingPathComponent("cmux.json")
            try Data(json.utf8).write(to: url)
            let controller = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                                managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
            await controller.reload()
            services.settings = controller
        }
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil, sessionEvents: true), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let result: Result<Void, any Error>
        do {
            try await PinnedPageTests.until({ services.daemon.store.workspaces.contains { $0.screens.contains { !$0.panes.isEmpty } } }, within: .seconds(90))
            try await PinnedPageTests.until({ services.windows.active?.workspaceContent?.panes.isEmpty == false }, within: .seconds(30))
            result = .success(try await body(services, try #require(services.daemon.connection)))
        } catch { result = .failure(error) }
        if let connection = services.daemon.connection {
            services.daemon.shutdownConnection()
            await connection.close()
            _ = try? await connection.shutdownDaemon(endTerminals: true)
        }
        try result.get()
    }
}
