import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTabs
import Darwin
import Foundation
import Testing

/// Lawrence 2026-11-13: "the performance of holding down a key to create new tab or new browser is also slow,
/// i think it got regressed". A held new-tab key (Ctrl-`, Cmd-Shift-L, Cmd-T) makes one tab per key repeat: each
/// press shows its tab in the key's own turn, right after the tab made by the press before it, whatever the
/// daemon has answered. The daemon is stopped while the keys are pressed, so no answer can come between two
/// presses on any host: a press that waits for the one before it shows no tab here. Then the daemon runs, the
/// tabs are its own in the same order, and a held Cmd-W closes them newest first, back to the first tab.
@MainActor @Suite(.serialized, .timeLimit(.minutes(6)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HeldNewTabKeyTests {
    private static let presses = 6

    enum Key: String, CaseIterable, Sendable {
        case terminal, browser, page
        var press: (characters: String, flags: NSEvent.ModifierFlags, code: UInt16) {
            switch self {
            case .terminal: ("`", [.control], 50)
            case .browser: ("l", [.command, .shift], 37)
            case .page: ("t", [.command], 17)
            }
        }
    }

    /// A held key's later run goes through the test window (a test window is never the key window).
    private static let testWindowReplay: HeldKeyReplay = { event, window, router in
        if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
    }

    /// A key-down through the app's key path: the key router, then the window. True when the router took it.
    @discardableResult
    private static func press(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16, repeats: Bool, in window: NSWindow,
                              _ services: AppServices) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                  isARepeat: repeats, keyCode: code))
        let taken = services.keyRouter.interceptKeyDown(event, in: window)
        if !taken { window.sendEvent(event) }
        return taken
    }

    @Test(arguments: Key.allCases)
    func aHeldNewTabKeyShowsOneTabPerRepeatInPressOrder(key: Key) async throws {
        try await PasswordManagerRouteTests.withApp(heldKeyReplay: Self.testWindowReplay) { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-held-new-tab")
            if key == .page { try #require(services.agentTabs.canHostChat, "this build has no New Tab page") }
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let pane = try #require(controller.focusedPane)
            let store = services.daemon.store
            let handle = pane.pane.handle
            window.setFrame(NSRect(x: 100, y: 100, width: 1500, height: 700), display: true)
            @MainActor func daemonTabs() -> [String] { store.pane(handle)?.tabs.map(\.id) ?? [] }
            @MainActor func strip() -> [String] { pane.orderedIDs.map(\.rawValue) }

            // `[a] b`: the pane's first tab and a page after it.
            let a = try #require(strip().first, "the pane has no first tab")
            let page = try await connection.newFrontendBrowserTab(url: "https://example.com/b", engine: .webkit, in: handle, activate: false)
            try await PasswordManagerRouteTests.until({ store.tab(surface: page.surface).map { strip().contains($0.id) } == true })
            let b = try #require(store.tab(surface: page.surface)).id
            pane.select(TabID(a))
            try #require(pane.stripModel.selectedID?.rawValue == a && strip() == [a, b], "the pane does not start as [a] b: \(strip())")
            try await PasswordManagerRouteTests.until({ !services.keyRouter.creationInputCoordinator.isHolding(in: window) },
                                            report: { "a key hold of the setup never ended" })

            let frames = NewTabBurstOrderAndCloseTests.Frames(a: a, b: b)
            let pid = try #require(services.daemon.identity?.pid)
            #expect(kill(pid, SIGSTOP) == 0)
            var resumed = false
            defer { if !resumed { kill(pid, SIGCONT) } }
            var shownAtPress: [Int] = []
            let stroke = key.press
            for press in 1...Self.presses {
                try Self.press(stroke.characters, stroke.flags, code: stroke.code, repeats: press > 1, in: window, services)
                frames.sample("press \(press)", pane, store: daemonTabs())
                shownAtPress.append(strip().count - 2)
                try await Task.sleep(for: .milliseconds(30)) // key repeat
            }
            frames.sample("pressed", pane, store: daemonTabs())
            let shown = strip()
            #expect(shownAtPress == Array(1...Self.presses),
                    "\(key.rawValue): a press did not show its tab in its own turn (new tabs shown after each press: \(shownAtPress)): \(frames.report)")
            #expect(shown.count == Self.presses + 2 && shown.first == a && shown.last == b,
                    "\(key.rawValue): the strip is not a, \(Self.presses) new tabs, b with the daemon stopped: \(frames.report)")
            #expect(pane.stripModel.selectedID?.rawValue == shown.dropLast().last, "\(key.rawValue): the newest tab is not selected: \(frames.report)")

            #expect(kill(pid, SIGCONT) == 0)
            resumed = true
            @MainActor func made() -> [String] { daemonTabs().filter { $0 != a && $0 != b && !ProvisionalTab.isProvisional($0) } }
            let deadline = ContinuousClock.now + .seconds(40)
            while ContinuousClock.now < deadline {
                frames.sample("settle", pane, store: daemonTabs())
                if made().count == Self.presses, strip() == daemonTabs(), !NewTabSuccession.isOpen(in: pane.pane),
                   !services.keyRouter.creationInputCoordinator.isHolding(in: window) { break }
                try await Task.sleep(for: .milliseconds(15))
            }
            #expect(made().count == Self.presses, "\(key.rawValue): the daemon made \(made().count) tabs for \(Self.presses) presses: \(frames.report)")
            #expect(daemonTabs().first == a && daemonTabs().last == b && strip() == daemonTabs(),
                    "\(key.rawValue): the daemon's order is not a, the new tabs, b: \(frames.report)")

            // A held Cmd-W: each close selects the tab on the left, the one the closed tab was made from.
            var wrong: [String] = []
            for close in 1...Self.presses {
                let left = Self.presses - close, before = strip()
                let expected = before.indices.contains(left) ? before[left] : nil
                try Self.press("w", [.command], code: 13, repeats: close > 1, in: window, services)
                frames.sample("close \(close)", pane, store: daemonTabs())
                if strip().count != left + 2 { wrong.append("close \(close) left \(strip().count - 2) new tabs, not \(left)") }
                if pane.stripModel.selectedID?.rawValue != expected { wrong.append("close \(close) did not select the tab on the left") }
                try await Task.sleep(for: .milliseconds(30))
            }
            try await PasswordManagerRouteTests.until({ daemonTabs() == [a, b] && strip() == [a, b] }, within: .seconds(30),
                                            report: { "\(key.rawValue): the closes never left a b: \(frames.report)" })
            #expect(pane.stripModel.selectedID?.rawValue == a, "\(key.rawValue): the closes did not end on the first tab: \(frames.report)")
            #expect(wrong.isEmpty, "\(key.rawValue): \(wrong.joined(separator: "; ")) \(frames.report)")
        }
    }
}
