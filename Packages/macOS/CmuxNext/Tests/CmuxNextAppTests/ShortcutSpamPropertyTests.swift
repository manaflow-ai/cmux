import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// Shortcut spam (handoff input-principles.md, Lawrence 2026-10-28: "spamming it very fast must work perfectly,
/// very fast"): random sequences of the window shortcuts (Cmd-W, Cmd-T, Cmd-N, Cmd-D, Ctrl-`, Cmd-1...9,
/// Ctrl-Tab, Cmd-Shift-[ / ], Cmd-Shift-T) pressed 0-5 ms apart through the real key router, as
/// `CmuxApplication.sendEvent` dispatches them, against a same-tree cmux-tui daemon whose replies and events
/// reach the app 0-500 ms late. The delay is the only perturbation the protocol allows on one connection: the
/// control stream is one FIFO (cmux-tui/spec/transports.md, "Reply and event order"), so bytes are delayed but
/// never reordered (``SpamReplyDelayProxy``).
///
/// Three properties, each its own expectation:
/// 1. Every press changes the app's local model in its own turn as its action says, exactly once: one
///    registry run of the shortcut's action in the press's turn (none: the dispatcher dropped or held the key;
///    two: doubled), and the local effect (``SpamVerdict``).
/// 2. Once the store has no pending intents, rows or provisional ids, the app equals the daemon: the same
///    workspaces, panes and tab ids in the same order, and once the system is quiet (no intent, no provisional id,
///    the last reply applied) each shown pane selects the daemon's active tab (the lead, 2026-10-28: a selection that
///    still differs when nothing is on its way is a real bug).
/// 3. The final tab counts equal the press list replayed on a tiny reference model (``SpamReference``).
///
/// It records what is red on a tip: run it on the fleet (`package-test-lane.sh suite Packages/macOS/CmuxNext
/// ShortcutSpamPropertyTests`). Each seed prints its trace.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ShortcutSpamPropertyTests {
    static let presses = 40
    /// Bounds that keep the sequence away from silly states: tabs per workspace, workspaces, shown panes.
    static let maxTabs = 12
    static let maxWorkspaces = 5
    static let maxPanes = 4

    @Test(arguments: [0x5EED_0001, 0x5EED_0002, 0x5EED_0003, 0x5EED_0004] as [UInt64])
    func randomShortcutSpamRunsOneActionPerPressAndEndsWithTheAppEqualToTheDaemon(_ seed: UInt64) async throws {
        let label = "seed 0x\(String(seed, radix: 16))"
        print("ShortcutSpamPropertyTests \(label): \(Self.presses) presses 0-5 ms apart, daemon replies 0-500 ms late")
        let proxy = try SpamReplyDelayProxy(seed: seed, maxDelayMilliseconds: 500)
        defer { proxy.stop() }
        try await Self.withProxiedApp(proxy) { services, connection in
            try await Self.spam(label, seed: seed, services, connection)
        }
    }

    // MARK: The run

    static func spam(_ label: String, seed: UInt64, _ services: AppServices, _ connection: DaemonConnection) async throws {
        let window = try #require(services.windows.active)
        let shell = try #require(window.window)
        let content = try #require(window.workspaceContent)
        // A focused pane, as a person's window has: Cmd-T and Cmd-W act on it.
        if content.focusedPane == nil, let first = content.panes.values.min(by: { $0.paneKey < $1.paneKey }) {
            PaneHandlers.focus(first.layoutPaneID, in: content)
        }
        try await PinnedPageTests.until({ services.windows.active?.workspaceContent?.focusedPane != nil }, report: { "no pane is focused" })
        let keys = try resolvedKeys(label, services, shell)

        let recorder = SpamRecorder()
        recorder.install(services.registry)
        let initial = SpamLocal.capture(services)
        var reference = SpamReference(tabs: initial.workspaces, current: initial.workspace)
        var rng = SpamRandom(seed: seed)
        var trace = ["\(label) start: \(initial.brief)"]
        for index in 0 ..< presses {
            let roll = rng.next() % 100, digitRoll = rng.next(), pause = rng.next() % 5001
            let before = SpamLocal.capture(services)
            let order = window.sidebar.model.itemOrder, settings = SidebarNavigation.settings(services)
            let key = bounded(SpamKey.weighted(roll), digitRoll: digitRoll, before: before, reference: reference,
                              workspaceDigits: (1 ... 9).filter { if case .workspace(_)? = order.pick($0, settings) { true } else { false } })
            let picked: SidebarItem? = if case .workspace(let digit) = key { order.pick(digit, settings) } else { nil }
            let choice = try #require(keys[key])
            let event = try Self.event(key, choice.characters, in: shell)

            // The press, in one turn: dispatched as CmuxApplication.sendEvent does, then read back at once.
            recorder.begin(index)
            let consumed = services.keyRouter.dispatchingSynthetic(event) { services.keyRouter.interceptKeyDown(event, in: shell) }
            recorder.end()
            let after = SpamLocal.capture(services)

            let ids = Set([key.action, choice.resolved])
            let runs = recorder.turnRuns.filter(ids.contains).count
            let refusals = recorder.turnRefusals
            #expect(consumed && runs == 1, """
                \(label) press \(index) \(key): \(consumed ? "" : "the router did not take the key; ")\(runs) runs of \(key.action) \
                in its turn (want 1; all runs \(recorder.turnRuns), refusals \(refusals))
                """)
            let verdict = SpamVerdict.judge(key, before: before, after: after, picked: picked.map { String(describing: Optional($0)) },
                                            reopens: !reference.closed.isEmpty)
            #expect(verdict.failure == nil, "\(label) press \(index) \(key): \(verdict.failure ?? "") (runs \(recorder.turnRuns), refusals \(refusals))")

            let made = key == .newWorkspace ? newWorkspace(before: before, after: after) : nil
            let target: String? = if case .workspace(let id)? = picked { id.rawValue } else { nil }
            reference.apply(key, index: index, made: made, target: target)
            trace.append("#\(index) \(key) \(consumed ? "taken" : "NOT TAKEN") runs \(recorder.turnRuns) refusals \(refusals): "
                + "\(before.brief) -> \(after.brief)\(verdict.failure.map { "  FAIL \($0)" } ?? "")\(verdict.note.map { "  note \($0)" } ?? "")")
            try await Task.sleep(for: .microseconds(Int(pause)))
        }

        // 2. Settled, then app == daemon (events are still up to 500 ms behind the snapshot: poll).
        let settled = await settle(services)
        #expect(settled, "\(label): still pending after 20 s: \(pending(services))")
        var mismatches: [String] = []
        var selection: [String] = []
        var notes: [String] = []
        let deadline = ContinuousClock.now + .seconds(20)
        repeat {
            let tree = try await connection.snapshot().tree
            (mismatches, selection, notes) = compare(services, tree)
            if mismatches.isEmpty, selection.isEmpty { break }
            try await Task.sleep(for: .milliseconds(250))
        } while ContinuousClock.now < deadline
        #expect(mismatches.isEmpty, "\(label): app != daemon 20 s after settling: \(mismatches)")
        // Quiet: nothing on its way (settled, re-checked now) and the snapshot read after the last reply.
        let quiet = pending(services) == nil
        #expect(!quiet || selection.isEmpty, "\(label): the selection differs from the daemon's once quiet: \(selection)")

        // 3. The final counts against the replayed presses.
        let final = SpamLocal.capture(services)
        let (wrong, unclear) = reference.differences(from: final)
        #expect(wrong.isEmpty, "\(label): final tab counts differ from the replayed presses: \(wrong)")

        for (index, items) in recorder.late.sorted(by: { $0.key < $1.key }) { trace.append("after #\(index): \(items)") }
        trace.append("\(label) end: \(final.brief); reference \(reference.brief)")
        if !notes.isEmpty { trace.append("not asserted (strip-only local tabs): \(notes)") }
        if !quiet { trace.append("selection not judged: still pending \(pending(services) ?? "")") }
        if !unclear.isEmpty { trace.append("reference could not tell: \(unclear)") }
        print(trace.joined(separator: "\n"))
    }

    /// Each shortcut's key-down resolved through the registry before the run, so a wrong key code fails loudly
    /// instead of testing nothing. The first spelling that reaches the action is used.
    static func resolvedKeys(_ label: String, _ services: AppServices, _ shell: NSWindow) throws -> [SpamKey: SpamKeyChoice] {
        var keys: [SpamKey: SpamKeyChoice] = [:]
        for key in SpamKey.all {
            var seen: [String] = []
            var choice: SpamKeyChoice?
            for characters in key.spellings {
                let probe = try event(key, characters, in: shell)
                let resolved = services.registry.resolveShortcut(for: probe)
                let argument = resolved?.argument.map { "(\($0))" } ?? ""
                seen.append("\(characters.typed.debugDescription)/\(characters.ignoring.debugDescription) -> "
                    + (resolved.map { $0.id.rawValue + argument } ?? "nothing"))
                guard let resolved else { continue }
                if resolved.id.rawValue == key.action, key.argument == nil || resolved.argument == key.argument {
                    choice = SpamKeyChoice(characters: characters, resolved: resolved.id.rawValue)
                    break
                }
                if choice == nil { choice = SpamKeyChoice(characters: characters, resolved: resolved.id.rawValue) }
            }
            #expect(choice?.resolved == key.action, "\(label): \(key) does not resolve to \(key.action): \(seen)")
            keys[key] = try #require(choice, "\(label): \(key) resolves to nothing: \(seen)")
        }
        return keys
    }

    /// The weighted draw, kept inside the bounds: no Cmd-W on the model's or the window's last tab, no create
    /// past ``maxTabs``, no workspace past ``maxWorkspaces``, no split past ``maxPanes``; Cmd-k picks a digit the
    /// sidebar gives a workspace (top items such as Home count first in its numbering).
    static func bounded(_ drawn: SpamKey, digitRoll: UInt64, before: SpamLocal, reference: SpamReference, workspaceDigits: [Int]) -> SpamKey {
        let here = reference.current.flatMap { reference.tabs[$0] } ?? 0
        var key = drawn
        if key == .workspace(0) { key = workspaceDigits.isEmpty ? .ctrlTab : .workspace(workspaceDigits[Int(digitRoll % UInt64(workspaceDigits.count))]) }
        if key == .newWorkspace, reference.tabs.count >= maxWorkspaces { key = .newTab }
        if key == .splitRight, before.panes.count >= maxPanes { key = .newTerminal }
        if key.creates, here >= maxTabs || before.shownTotal >= maxTabs { key = .closeTab }
        if key == .closeTab, here <= 1 || before.shownTotal <= 1 { key = .newTab }
        return key
    }

    /// The workspace a Cmd-N made: its pending row, else a new store workspace, else the newly shown one.
    static func newWorkspace(before: SpamLocal, after: SpamLocal) -> String? {
        if let row = after.rows.first(where: { !before.rows.contains($0) }) { return row }
        if let made = after.workspaces.keys.first(where: { before.workspaces[$0] == nil }) { return made }
        guard let shown = after.workspace, shown != before.workspace, before.workspaces[shown] == nil else { return nil }
        return shown
    }

    static func event(_ key: SpamKey, _ characters: SpamKey.Characters, in shell: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.modifiers,
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shell.windowNumber, context: nil,
                                      characters: characters.typed, charactersIgnoringModifiers: characters.ignoring,
                                      isARepeat: false, keyCode: key.keyCode))
    }

    // MARK: Settle and compare

    static func settle(_ services: AppServices) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while pending(services) != nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        return pending(services) == nil
    }

    /// What is still on its way: the store's intents, pending workspace rows, provisional ids. Nil: nothing.
    static func pending(_ services: AppServices) -> String? {
        let intents = services.daemon.store.pendingIntents
        let rows = PendingWorkspaceRows.shared.rows
        let provisional = provisionalIDs(services)
        guard !intents.isEmpty || !rows.isEmpty || !provisional.isEmpty else { return nil }
        return "intents \(intents.map { String(describing: $0.intent) }), rows \(rows.map { $0.id }), provisional \(provisional)"
    }

    static func provisionalIDs(_ services: AppServices) -> [String] {
        var ids: [String] = []
        for workspace in services.daemon.store.workspaces {
            if ProvisionalWorkspace.isProvisional(workspace.handle) { ids.append("workspace \(workspace.id)") }
            for pane in workspace.screens.flatMap({ $0.panes }) {
                for tab in pane.tabs where ProvisionalTab.isProvisional(tab.id) || ProvisionalTab.isProvisional(surface: tab.surface) {
                    ids.append("tab \(tab.id)")
                }
            }
        }
        for controller in services.windows.active?.workspaceContent?.panes.values.map({ $0 }) ?? [] {
            for id in controller.orderedIDs where ProvisionalTab.isProvisional(id.rawValue) { ids.append("strip tab \(id.rawValue)") }
        }
        return ids
    }

    /// The app's store and shown strips against a fresh daemon snapshot: (mismatches, selection differences, notes).
    /// Notes are tabs only the strip has (app-local pages).
    static func compare(_ services: AppServices, _ tree: DaemonTree) -> ([String], [String], [String]) {
        var out: [String] = []
        var selection: [String] = []
        var notes: [String] = []
        var daemon: [String: WorkspaceSnapshot] = [:]
        for workspace in tree.workspaces { daemon[WorkspaceModel.identity(workspace)] = workspace }
        let app = services.daemon.store.workspaces
        let appIDs = Set(app.map { $0.id }), daemonIDs = Set(daemon.keys)
        if appIDs != daemonIDs {
            out.append("workspaces: app only \(appIDs.subtracting(daemonIDs).sorted()), daemon only \(daemonIDs.subtracting(appIDs).sorted())")
        }
        for workspace in app {
            guard let snapshot = daemon[workspace.id] else { continue }
            let mine = workspace.screens.flatMap { $0.panes }.map { pane in "\(pane.id): \(pane.tabs.map { $0.id })" }
            let theirs = snapshot.screens.flatMap { $0.panes }.map { pane in "\(PaneModel.identity(pane)): \(pane.tabs.map { TabModel.identity($0) })" }
            if mine != theirs { out.append("workspace \(workspace.id): app \(mine), daemon \(theirs)") }
        }
        if let content = services.windows.active?.workspaceContent, let snapshot = daemon[content.workspace.id] {
            let panes = snapshot.screens.flatMap { $0.panes }
            for controller in content.panes.values.sorted(by: { $0.paneKey < $1.paneKey }) {
                guard let theirs = panes.first(where: { $0.id == controller.pane.handle }) else {
                    out.append("shown pane \(controller.paneKey) is not in the daemon's workspace")
                    continue
                }
                let stored = Set(controller.pane.tabs.map { $0.id })
                let strip = controller.orderedIDs.map { $0.rawValue }
                let want = theirs.tabs.map { TabModel.identity($0) }
                if strip.filter(stored.contains) != want { out.append("pane \(controller.paneKey): strip \(strip), daemon \(want)") }
                let local = strip.filter { !stored.contains($0) }
                if !local.isEmpty { notes.append("pane \(controller.paneKey) strip-only tabs \(local)") }
                let daemonSelected = theirs.tabs.indices.contains(theirs.activeTab) ? TabModel.identity(theirs.tabs[theirs.activeTab]) : nil
                if controller.stripModel.selectedID?.rawValue != daemonSelected {
                    selection.append("pane \(controller.paneKey) selects \(controller.stripModel.selectedID?.rawValue ?? "nil"), daemon active tab \(daemonSelected ?? "nil")")
                }
            }
        }
        out += provisionalIDs(services).map { "provisional id remains: \($0)" }
        return (out, selection, notes)
    }

    // MARK: Harness

    /// `PinnedPageTests.withApp` with the app's daemon connection through `proxy`: the launcher's endpoint with
    /// only its socket path rewritten to the proxy's, which connects on to the daemon's own socket.
    static func withProxiedApp(_ proxy: SpamReplyDelayProxy, _ body: (AppServices, DaemonConnection) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-spam-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = DaemonLauncher(
            work: BackgroundWork(label: "test.daemon-launcher"),
            configuration: .init(binary: binary, session: "cn-spam-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        let upstream = launcher.endpointProvider
        let endpoints: DaemonConnection.EndpointProvider = { [proxy] in
            var endpoint = try await upstream()
            proxy.route(to: endpoint.socketPath)
            endpoint.socketPath = proxy.path
            return endpoint
        }
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil, sessionEvents: true), endpointProvider: endpoints)
        }
        services.windows.restoreWhenLoaded()
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let result: Result<Void, any Error>
        do {
            try await PinnedPageTests.until({ services.daemon.store.workspaces.contains { $0.screens.contains { !$0.panes.isEmpty } } }, within: .seconds(90))
            try await PinnedPageTests.until({ services.windows.active?.workspaceContent?.panes.isEmpty == false }, within: .seconds(30))
            result = .success(try await body(services, try #require(services.daemon.connection)))
        } catch { result = .failure(error) }
        // Stop the app's connection first: on the daemon's EOF it would start a fresh daemon that outlives the test.
        if let connection = services.daemon.connection {
            services.daemon.shutdownConnection()
            await connection.close()
            _ = try? await connection.shutdownDaemon(endTerminals: true)
        }
        try result.get()
    }
}

// MARK: Shortcuts

/// One shortcut of the fuzz with its default key (schemas/defaults/cmux-next.json, KeyBindingDefaults).
enum SpamKey: Hashable, CustomStringConvertible {
    case closeTab, newTab, newWorkspace, splitRight, newTerminal, ctrlTab, nextTab, prevTab, reopen
    /// Cmd-`digit`; `workspace(0)` is the draw before a digit is chosen.
    case workspace(Int)

    /// A key-down's `characters` and `charactersIgnoringModifiers`.
    struct Characters {
        var typed: String
        var ignoring: String
    }

    static let all: [SpamKey] = [.closeTab, .newTab, .newWorkspace, .splitRight, .newTerminal, .ctrlTab, .nextTab, .prevTab, .reopen]
        + (1 ... 9).map { SpamKey.workspace($0) }
    /// US key codes of 1...9.
    static let digitCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// Weights out of 100: creates (43) outweigh Cmd-W (22), so the strip grows and shrinks around a few tabs.
    static func weighted(_ roll: UInt64) -> SpamKey {
        let table: [(SpamKey, UInt64)] = [(.newTab, 18), (.newTerminal, 12), (.splitRight, 8), (.newWorkspace, 5), (.closeTab, 22),
                                          (.ctrlTab, 8), (.nextTab, 5), (.prevTab, 7), (.workspace(0), 10), (.reopen, 5)]
        var left = roll % 100
        for (key, weight) in table {
            if left < weight { return key }
            left -= weight
        }
        return .newTab
    }

    var creates: Bool { [.newTab, .newTerminal, .splitRight, .newWorkspace].contains(self) }

    var description: String {
        switch self {
        case .closeTab: "Cmd-W"
        case .newTab: "Cmd-T"
        case .newWorkspace: "Cmd-N"
        case .splitRight: "Cmd-D"
        case .newTerminal: "Ctrl-`"
        case .ctrlTab: "Ctrl-Tab"
        case .nextTab: "Cmd-Shift-]"
        case .prevTab: "Cmd-Shift-["
        case .reopen: "Cmd-Shift-T"
        case .workspace(let digit): "Cmd-\(digit)"
        }
    }

    var action: String {
        switch self {
        case .closeTab: "closeTab"
        case .newTab: "newTab.default"
        case .newWorkspace: "newTab"
        case .splitRight: "splitRight"
        case .newTerminal: "newSurface"
        case .ctrlTab, .nextTab: "nextSurface"
        case .prevTab: "prevSurface"
        case .reopen: "reopenClosedBrowserPanel"
        case .workspace: "selectWorkspaceByNumber"
        }
    }

    var argument: String? { if case .workspace(let digit) = self { String(digit) } else { nil } }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .newTerminal, .ctrlTab: [.control]
        case .nextTab, .prevTab, .reopen: [.command, .shift]
        default: [.command]
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .closeTab: 13
        case .newTab, .reopen: 17
        case .newWorkspace: 45
        case .splitRight: 2
        case .newTerminal: 50
        case .ctrlTab: 48
        case .nextTab: 30
        case .prevTab: 33
        case .workspace(let digit): Self.digitCodes[max(0, min(8, digit - 1))]
        }
    }

    /// The spellings a key-down of it can have, the shifted one first (as AppKit reports a shifted key).
    var spellings: [Characters] {
        switch self {
        case .closeTab: [Characters(typed: "w", ignoring: "w")]
        case .newTab: [Characters(typed: "t", ignoring: "t")]
        case .newWorkspace: [Characters(typed: "n", ignoring: "n")]
        case .splitRight: [Characters(typed: "d", ignoring: "d")]
        case .newTerminal: [Characters(typed: "`", ignoring: "`")]
        case .ctrlTab: [Characters(typed: "\t", ignoring: "\t")]
        case .nextTab: [Characters(typed: "}", ignoring: "}"), Characters(typed: "}", ignoring: "]"), Characters(typed: "]", ignoring: "]")]
        case .prevTab: [Characters(typed: "{", ignoring: "{"), Characters(typed: "{", ignoring: "["), Characters(typed: "[", ignoring: "[")]
        case .reopen: [Characters(typed: "T", ignoring: "T"), Characters(typed: "T", ignoring: "t"), Characters(typed: "t", ignoring: "t")]
        case .workspace(let digit): [Characters(typed: String(digit), ignoring: String(digit))]
        }
    }
}

/// The spelling of a shortcut the run presses and the action the registry resolved it to.
struct SpamKeyChoice {
    var characters: SpamKey.Characters
    var resolved: String
}

// MARK: Oracle

/// The app's local model as the person sees it, read in the press's own turn: the shown workspace, its
/// panes' strips, the focused pane, the sidebar selection, and each store workspace's tab count.
struct SpamLocal {
    struct Pane {
        var key: String
        var tabs: [String]
        var selected: String?
    }

    var workspace: String?
    var selection: String
    var panes: [Pane]
    var focused: String?
    var workspaces: [String: Int]
    var rows: [String]

    var shownTotal: Int { panes.reduce(0) { $0 + $1.tabs.count } }
    var storeTotal: Int { workspaces.values.reduce(0, +) }
    func pane(_ key: String?) -> Pane? { panes.first { $0.key == key } }

    var brief: String {
        let strips = panes.map { "\($0.key == focused ? "*" : "")\($0.tabs.count)" }.joined(separator: ",")
        return "ws \(workspace.map { String($0.suffix(6)) } ?? "nil") [\(strips)] shown \(shownTotal) store \(storeTotal) in \(workspaces.count) ws"
    }

    static func capture(_ services: AppServices) -> SpamLocal {
        let window = services.windows.active
        let content = window?.workspaceContent
        let panes = (content?.panes.values.map { $0 } ?? []).sorted { $0.paneKey < $1.paneKey }
            .map { Pane(key: $0.paneKey, tabs: $0.orderedIDs.map { $0.rawValue }, selected: $0.stripModel.selectedID?.rawValue) }
        var counts: [String: Int] = [:]
        for workspace in services.daemon.store.workspaces {
            counts[workspace.id] = workspace.screens.reduce(0) { $0 + $1.panes.reduce(0) { $0 + $1.tabs.count } }
        }
        let selection = window.map { String(describing: $0.sidebar.model.itemOrder.stop(for: SidebarNavigation.current(in: $0, services))) } ?? "no window"
        return SpamLocal(workspace: window?.state.workspaceID, selection: selection, panes: panes, focused: content?.focusedPane?.paneKey,
                         workspaces: counts, rows: PendingWorkspaceRows.shared.rows.map { $0.id })
    }
}

/// What one press should have changed in its own turn. `failure`: it did not; `note`: no rule to judge by.
struct SpamVerdict {
    var failure: String?
    var note: String?

    static func judge(_ key: SpamKey, before: SpamLocal, after: SpamLocal, picked: String?, reopens: Bool) -> SpamVerdict {
        let tabs = "shown tabs \(before.shownTotal) -> \(after.shownTotal)"
        switch key {
        case .closeTab:
            guard before.shownTotal > 1 else { return SpamVerdict(note: "the window's last tab: close rules not modelled") }
            if after.workspace != before.workspace { return SpamVerdict(failure: "the shown workspace changed (\(before.brief) -> \(after.brief))") }
            if after.shownTotal != before.shownTotal - 1 { return SpamVerdict(failure: "\(tabs), want \(before.shownTotal - 1)") }
            if let pane = before.pane(before.focused), pane.tabs.count > 1, after.pane(pane.key)?.tabs.count != pane.tabs.count - 1 {
                return SpamVerdict(failure: "closed a tab outside the focused pane (\(before.brief) -> \(after.brief))")
            }
        case .newTab, .newTerminal:
            if after.workspace != before.workspace { return SpamVerdict(failure: "the shown workspace changed (\(before.brief) -> \(after.brief))") }
            if after.shownTotal != before.shownTotal + 1 { return SpamVerdict(failure: "\(tabs), want \(before.shownTotal + 1)") }
        case .splitRight:
            if after.panes.count != before.panes.count + 1 || after.shownTotal != before.shownTotal + 1 {
                return SpamVerdict(failure: "panes \(before.panes.count) -> \(after.panes.count), \(tabs); want one more of each")
            }
            if after.focused == before.focused { return SpamVerdict(note: "the new pane is not focused") }
        case .newWorkspace:
            guard let shown = after.workspace, shown != before.workspace, before.workspaces[shown] == nil else {
                let rows = after.rows.filter { !before.rows.contains($0) }
                return SpamVerdict(failure: "no new workspace shown in its turn (\(before.brief) -> \(after.brief), new rows \(rows))")
            }
        case .workspace:
            let want = picked ?? before.selection
            if after.selection != want { return SpamVerdict(failure: "selects \(after.selection), want \(want)") }
        case .ctrlTab, .nextTab, .prevTab:
            guard let pane = before.pane(before.focused) else { return SpamVerdict(note: "no focused pane") }
            let step = key == .prevTab ? -1 : 1
            guard pane.tabs.count > 1, let selected = pane.selected, let index = pane.tabs.firstIndex(of: selected) else {
                return after.pane(pane.key)?.selected == pane.selected ? SpamVerdict() : SpamVerdict(failure: "a one-tab pane changed its selection")
            }
            let want = pane.tabs[(index + step + pane.tabs.count) % pane.tabs.count]
            if after.focused != pane.key { return SpamVerdict(failure: "the focus left pane \(pane.key) for \(after.focused ?? "nil")") }
            if after.pane(pane.key)?.selected != want {
                return SpamVerdict(failure: "selects \(after.pane(pane.key)?.selected ?? "nil"), want \(want) (from \(selected) in \(pane.tabs))")
            }
        case .reopen:
            guard reopens else { return SpamVerdict(note: "nothing closed in this run: \(tabs)") }
            if after.storeTotal != before.storeTotal + 1, after.shownTotal != before.shownTotal + 1 {
                return SpamVerdict(failure: "reopened nothing in its turn (store tabs \(before.storeTotal) -> \(after.storeTotal), \(tabs))")
            }
        }
        return SpamVerdict()
    }
}

/// The press list replayed on tab counts only (which pane gets the focus after a close does not change a
/// workspace's count). Per workspace:
/// - Cmd-T, Ctrl-`, Cmd-D: one more tab in the current workspace;
/// - Cmd-W: one less (the run never presses it on a workspace's last tab), and the close is remembered;
/// - Cmd-Shift-T: the newest remembered close comes back (+1 in its workspace); none: nothing;
/// - Cmd-N: a new workspace with one tab becomes current (its id from the press's turn, else unclear);
/// - Cmd-k: the workspace the sidebar's digit picked at the press becomes current;
/// - Ctrl-Tab, Cmd-Shift-[ / ]: no change.
struct SpamReference {
    var tabs: [String: Int]
    var current: String?
    var closed: [String] = []
    /// Workspaces whose count no rule predicts, with why: printed, not asserted.
    var unclear: [String: String] = [:]

    var brief: String { tabs.keys.sorted().map { "\($0.suffix(6))=\(tabs[$0] ?? 0)" }.joined(separator: " ") }

    mutating func apply(_ key: SpamKey, index: Int, made: String?, target: String?) {
        switch key {
        case .newTab, .newTerminal, .splitRight:
            guard let current else { return }
            tabs[current, default: 0] += 1
        case .closeTab:
            guard let current else { return }
            if tabs[current, default: 0] > 1 {
                tabs[current, default: 0] -= 1
                closed.append(current)
            } else {
                unclear[current] = "Cmd-W #\(index) on its last tab"
            }
        case .reopen:
            if let workspace = closed.popLast() { tabs[workspace, default: 0] += 1 }
        case .newWorkspace:
            let id = made ?? "unshown-\(index)"
            if made == nil { unclear[id] = "Cmd-N #\(index) showed no workspace and made no row in its turn" }
            tabs[id] = 1
            current = id
        case .workspace:
            if let target { current = target }
        case .ctrlTab, .nextTab, .prevTab:
            break
        }
    }

    /// (mismatches, unclear) between the model and the app's final store counts.
    func differences(from final: SpamLocal) -> ([String], [String]) {
        var wrong: [String] = []
        var unsure = unclear.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        for (id, count) in tabs.sorted(by: { $0.key < $1.key }) where unclear[id] == nil {
            guard let actual = final.workspaces[id] else {
                wrong.append("workspace \(id) (\(count) tabs predicted) is not in the app")
                continue
            }
            if actual != count { wrong.append("workspace \(id): \(actual) tabs, predicted \(count)") }
        }
        let extra = final.workspaces.keys.filter { tabs[$0] == nil }.sorted()
        let unshown = tabs.keys.filter { $0.hasPrefix("unshown-") }.count
        if extra.count > unshown {
            wrong.append("workspaces no press made: \(extra.map { "\($0)=\(final.workspaces[$0] ?? 0)" })")
        } else if !extra.isEmpty {
            unsure.append("workspaces made by unshown Cmd-N presses: \(extra.map { "\($0)=\(final.workspaces[$0] ?? 0)" })")
        }
        return (wrong, unsure)
    }
}

/// What the registry did during each press's turn and between presses (a held key that runs later shows
/// under the press before it).
final class SpamRecorder {
    private(set) var press = -1
    private var inTurn = false
    private(set) var turnRuns: [String] = []
    private(set) var turnRefusals: [String] = []
    private(set) var late: [Int: [String]] = [:]

    func install(_ registry: ActionRegistry) {
        registry.willRunObservers.append { [weak self] id, _ in self?.ran(id.rawValue) }
        let shown = registry.refusalObserver
        registry.refusalObserver = { [weak self] reason, quiet in
            self?.refused(quiet ? "quiet: \(reason)" : reason)
            shown?(reason, quiet)
        }
    }

    func begin(_ index: Int) {
        press = index
        inTurn = true
        turnRuns = []
        turnRefusals = []
    }

    func end() { inTurn = false }

    private func ran(_ id: String) {
        if inTurn { turnRuns.append(id) } else { late[press, default: []].append("run \(id)") }
    }

    private func refused(_ reason: String) {
        if inTurn { turnRefusals.append(reason) } else { late[press, default: []].append("refusal \(reason)") }
    }
}

// MARK: Reply delay seam

/// SplitMix64: a small seeded generator, so a seed replays its presses, pauses and delays.
nonisolated struct SpamRandom: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// A Unix-socket byte proxy between the app and the daemon. Each accepted connection gets its own connection
/// to the daemon's socket and two pumps on background threads. App to daemon: as read. Daemon to app: each read
/// chunk k is delivered at max(deliver(k-1), received(k) + jitter), jitter 0...max from the connection's own
/// seeded generator: delayed, never reordered (one connection's control stream is one FIFO; connections are
/// delayed independently).
nonisolated final class SpamReplyDelayProxy: Sendable {
    let path: String
    private let listener: Int32
    private let seed: UInt64
    private let maxDelay: UInt64
    private let state = Mutex<State>(State())

    private nonisolated struct State: Sendable {
        var upstream: String?
        var accepted: UInt64 = 0
        var pairs: [UInt64: Pair] = [:]
        var stopped = false
    }

    /// One proxied connection's two sockets, and how many of its pumps still run.
    private nonisolated struct Pair: Sendable {
        var client: Int32
        var daemon: Int32
        var running = 2
    }

    init(seed: UInt64, maxDelayMilliseconds: UInt64) throws {
        path = "/tmp/cmux-spf-\(String(UInt32.random(in: 0 ... .max), radix: 16)).sock"
        self.seed = seed
        maxDelay = maxDelayMilliseconds * 1_000_000
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EMFILE) }
        let listener = listener
        guard Self.withAddress(path, { bind(listener, $0, $1) }) == 0, listen(listener, 16) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        Self.spawn("cmux-spf.accept") { [self] in acceptLoop() }
    }

    /// The daemon socket the next connections go to (the launcher's endpoint, read per connect).
    func route(to upstream: String) { state.withLock { $0.upstream = upstream } }

    /// Stops accepting and ends every proxied connection.
    func stop() {
        state.withLock { state in
            state.stopped = true
            for pair in state.pairs.values {
                shutdown(pair.client, SHUT_RDWR)
                shutdown(pair.daemon, SHUT_RDWR)
            }
        }
        unlink(path)
    }

    private func acceptLoop() {
        while !state.withLock({ $0.stopped }) {
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let polled = poll(&ready, 1, 200)
            if polled < 0, errno != EINTR { break }
            guard polled > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            Self.noSigPipe(client)
            let (upstream, index) = state.withLock { state -> (String?, UInt64) in
                state.accepted += 1
                return (state.upstream, state.accepted)
            }
            guard let upstream, let daemon = Self.connect(upstream) else {
                close(client)
                continue
            }
            let admitted = state.withLock { state -> Bool in
                guard !state.stopped else { return false }
                state.pairs[index] = Pair(client: client, daemon: daemon)
                return true
            }
            guard admitted else {
                close(client)
                close(daemon)
                break
            }
            let delaySeed = seed ^ (index &* 0x9E37_79B9_7F4A_7C15), maxDelay = maxDelay
            Self.spawn("cmux-spf.up.\(index)") { [self] in
                Self.pump(from: client, to: daemon, delaySeed: nil, maxDelay: 0)
                finished(index)
            }
            Self.spawn("cmux-spf.down.\(index)") { [self] in
                Self.pump(from: daemon, to: client, delaySeed: delaySeed, maxDelay: maxDelay)
                finished(index)
            }
        }
        close(listener)
    }

    /// A pump ended: the second one closes both sockets (after taking them out of `pairs`, so `stop` never
    /// shuts a descriptor number the system gave to someone else).
    private func finished(_ index: UInt64) {
        let done = state.withLock { state -> Pair? in
            guard var pair = state.pairs[index] else { return nil }
            pair.running -= 1
            state.pairs[index] = pair.running > 0 ? pair : nil
            return pair.running > 0 ? nil : pair
        }
        if let done {
            close(done.client)
            close(done.daemon)
        }
    }

    /// Copies `source` to `destination` until `source` ends, each chunk at its delivery time (no delay without
    /// a seed), then ends `destination`'s writing half so the peer sees the end.
    private static func pump(from source: Int32, to destination: Int32, delaySeed: UInt64?, maxDelay: UInt64) {
        var random = SpamRandom(seed: delaySeed ?? 0)
        var queue: [(at: UInt64, bytes: [UInt8])] = []
        var lastDelivery: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var reading = true, writing = true
        while writing, reading || !queue.isEmpty {
            let now = DispatchTime.now().uptimeNanoseconds
            while writing, let first = queue.first, first.at <= now {
                queue.removeFirst()
                writing = writeAll(destination, first.bytes)
            }
            guard writing else { break }
            let wait = queue.first.map { Int32(clamping: ($0.at - now) / 1_000_000 + 1) } ?? 250
            guard reading else {
                _ = poll(nil, 0, wait)
                continue
            }
            var descriptor = pollfd(fd: source, events: Int16(POLLIN), revents: 0)
            let polled = poll(&descriptor, 1, wait)
            if polled < 0, errno != EINTR { reading = false }
            guard polled > 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                reading = false
                continue
            }
            let received = DispatchTime.now().uptimeNanoseconds
            let jitter = delaySeed == nil ? 0 : random.next() % (maxDelay + 1)
            let at = max(lastDelivery, received + jitter)
            lastDelivery = at
            queue.append((at: at, bytes: Array(buffer[0 ..< count])))
        }
        shutdown(destination, SHUT_WR)
    }

    private static func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    private static func connect(_ path: String) -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        guard withAddress(path, { Darwin.connect(descriptor, $0, $1) }) == 0 else {
            close(descriptor)
            return nil
        }
        noSigPipe(descriptor)
        return descriptor
    }

    private static func noSigPipe(_ descriptor: Int32) {
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private static func spawn(_ name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
