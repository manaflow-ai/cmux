import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// Keys typed right after Ctrl-1…9 (Select Tab by Number) selects a terminal tab this window
/// never showed reach that tab's terminal (hq#1925 item 3, cx-wb5.76). Such a tab has no surface
/// yet: the pane empties at once and makes the surface on a later frame, 100-350 ms on a busy Mac,
/// and until then the window itself was the first responder, so those keys went nowhere.
/// Judged by the input journal's byte counts per terminal, on the real daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SwitchToColdTabTypeAheadTests {
    private static func wait(within limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Input bytes the journal saw per terminal surface since `after` (a journal sequence number).
    private static func inputBytes(after: UInt64) -> [String: Int] {
        var bytes: [String: Int] = [:]
        for entry in InputJournal.shared.entries() where entry.seq > after {
            if case .attach(let attach) = entry.kind, attach.event == "input" { bytes[attach.surface, default: 0] += attach.bytes }
        }
        return bytes
    }

    private static func lastSeq() -> UInt64 { InputJournal.shared.entries(last: 1).last?.seq ?? 0 }

    /// The one tab `pane` lists beyond `known`, once it is the daemon's. `newSurface` shows a
    /// stand-in first (`pending_tab_…`, ctrl-backtick-instant), and the daemon's tab takes its
    /// place a round trip later. A script's tab is cold either way; this test selects the daemon's,
    /// whose surface attaches, so the journal's per-surface input counts see its keys.
    private static func daemonTab(in pane: PaneController, beyond known: Set<String>) -> String? {
        let fresh = pane.orderedIDs.map(\.rawValue).filter { !known.contains($0) }
        guard fresh.count == 1, let tab = fresh.first, !ProvisionalTab.isProvisional(tab) else { return nil }
        return tab
    }

    /// The Ctrl-<number> that selects `tab` in `pane`.
    private static func number(of tab: String, in pane: PaneController) throws -> Int {
        try #require(pane.orderedIDs.firstIndex { $0.rawValue == tab }) + 1
    }

    /// A plain key-down, delivered as `CmuxApplication.sendEvent` delivers it.
    private static func type(_ text: String, in window: NSWindow, router: KeyRouter) {
        let codes: [Character: UInt16] = ["h": 4, "e": 14, "l": 37, "o": 31, "x": 7, "s": 1, "\u{03}": 8]
        for character in text {
            // ^C is Control-C, a chord the terminal takes.
            let control = character == "\u{03}"
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: control ? [.control] : [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: String(character),
                                               charactersIgnoringModifiers: control ? "c" : String(character), isARepeat: false,
                                               keyCode: codes[character] ?? 0) else { continue }
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        }
    }

    @Test func keysTypedRightAfterSelectingAColdTabReachItsTerminal() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-coldtab-\(UUID().uuidString.prefix(8))")
        let session = "cn-coldtab-\(UUID().uuidString.prefix(8).lowercased())"
        // The journal's attach observer is chosen when a terminal attaches: on before launch.
        InputJournal.shared.configure(InputJournalPolicy(enabled: true, recordsCharacters: false))
        let launcher = DaemonLauncher(
            work: BackgroundWork(label: "test.daemon-launcher"),
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        let services = TestHosts.liveDaemonApp()
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        defer {
            if let connection = services.daemon.connection, let identity = services.daemon.identity {
                Task { _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                                         timeout: .seconds(10)) }
            }
            for controller in services.windows.controllers { controller.window?.close() }
            try? FileManager.default.removeItem(at: root)
        }

        // The launch window opens a page; a terminal tab opened from the keyboard is shown and has it.
        await Self.wait(within: .seconds(90)) { services.windows.active?.focusedPane != nil && services.daemon.connection != nil }
        let controller = try #require(services.windows.active)
        let window = try #require(controller.window)
        let pane = try #require(controller.focusedPane)
        _ = services.registry.perform("newSurface", invocation: ActionInvocation(origin: .user))
        await Self.wait(within: .seconds(60)) { window.firstResponder is TerminalSurfaceView }
        try #require(window.firstResponder is TerminalSurfaceView, "the new terminal never took the keyboard")
        let router = services.keyRouter
        // The keys must wait for the surface itself, not for the hold's bound.
        router.creationInputCoordinator.holdLimit = .seconds(60)
        // Its terminal, by one key typed there.
        var seq = Self.lastSeq()
        Self.type("x", in: window, router: router)
        await Self.wait(within: .seconds(10)) { !Self.inputBytes(after: seq).isEmpty }
        let shown = try #require(Self.inputBytes(after: seq).keys.first, "the shown terminal got no input")

        // The first tab is still its stand-in (`pending_tab_…`) until the daemon's reply swaps in the daemon's tab: wait
        // for that state, so the list below names the daemon's tabs and the script's tab is the only new one.
        await Self.wait(within: .seconds(30)) { pane.orderedIDs.allSatisfy { !ProvisionalTab.isProvisional($0.rawValue) } }
        // A second terminal tab made by a script: the window does not show it, so it has no surface.
        let before = Set(pane.orderedIDs.map(\.rawValue))
        _ = services.registry.perform("newSurface", invocation: ActionInvocation(origin: .cli))
        await Self.wait(within: .seconds(30)) { Self.daemonTab(in: pane, beyond: before) != nil }
        let cold = try #require(Self.daemonTab(in: pane, beyond: before), "the script's tab never became the daemon's: \(pane.orderedIDs)")
        let number = try Self.number(of: cold, in: pane)
        #expect(pane.currentTabKey != cold, "the script's tab was shown")
        #expect(!services.cache.hasContent(for: cold), "the script's tab already has a surface")

        // Ctrl-<its number>, then typing at once.
        seq = Self.lastSeq()
        _ = services.registry.perform("selectSurfaceByNumber", invocation: ActionInvocation(arguments: ["index": .int(number)]))
        Self.type("hello", in: window, router: router)
        await Self.wait(within: .seconds(15)) { Self.inputBytes(after: seq).values.reduce(0, +) >= 5 }
        try? await Task.sleep(for: .milliseconds(300))  // a stray key would show by now
        let after = Self.inputBytes(after: seq)

        #expect(pane.currentTabKey == cold)
        #expect(after[shown] == nil, "keys typed after Ctrl-\(number) went to the tab it left: \(after)")
        #expect(after.count == 1 && after.values.first == 5, "the selected tab's terminal got \(after) of 5 typed bytes")

        // Another cold tab, then typing and a terminal chord behind it: the chord waits its turn.
        let listed = Set(pane.orderedIDs.map(\.rawValue))
        _ = services.registry.perform("newSurface", invocation: ActionInvocation(origin: .cli))
        await Self.wait(within: .seconds(30)) { Self.daemonTab(in: pane, beyond: listed) != nil }
        let second = try #require(Self.daemonTab(in: pane, beyond: listed), "the second script tab never became the daemon's: \(pane.orderedIDs)")
        #expect(!services.cache.hasContent(for: second), "the second script tab already has a surface")
        let secondNumber = try Self.number(of: second, in: pane)
        seq = Self.lastSeq()
        _ = services.registry.perform("selectSurfaceByNumber", invocation: ActionInvocation(arguments: ["index": .int(secondNumber)]))
        Self.type("ls\u{03}", in: window, router: router)
        await Self.wait(within: .seconds(15)) { Self.inputBytes(after: seq).values.reduce(0, +) >= 3 }
        try? await Task.sleep(for: .milliseconds(300))
        let chorded = Self.inputBytes(after: seq)
        #expect(pane.currentTabKey == second)
        #expect(chorded.count == 1 && chorded.values.first == 3, "typing then ^C onto a cold tab reached \(chorded) of 3 bytes")
    }
}
