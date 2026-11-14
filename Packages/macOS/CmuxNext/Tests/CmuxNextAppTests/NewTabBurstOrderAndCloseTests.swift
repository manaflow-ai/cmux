import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTabs
import Foundation
import Testing

/// Lawrence 2026-11-13: "if i spam new tab or new terminal very fast, then i close them, it is clear that
/// they were not made in the correct order, as if i close a tab, i get focused to the wrong tab."
/// A pane shows `a b` with `a` selected. A held new-tab key (New Tab page, terminal or browser) makes tabs
/// `1 2 3 ...`: each goes right after the tab the pane showed at its press, which is the one before it, so
/// the strip is `a 1 2 3 ... b` at every step and the newest is selected. A held Cmd-W then closes them
/// newest first: each close selects the tab the closed one was made from, the one on its left, down to `a`.
/// Nothing moves a tab that stays, and `b` is never selected.
@MainActor @Suite(.serialized, .timeLimit(.minutes(8)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabBurstOrderAndCloseTests {
    private static let presses = 8

    enum Kind: String, CaseIterable, Sendable {
        case page, terminal, browser
        var action: ActionID {
            switch self {
            case .page: "newTab.default"
            case .terminal: "newSurface"
            case .browser: "openBrowser"
            }
        }
    }

    /// The time between two presses: key repeat (30 ms), or the next main-actor turn (a main thread that
    /// stalled delivers the queued repeats back to back).
    enum Gap: String, CaseIterable, Sendable {
        case keyRepeat, nextTurn
        func wait() async throws {
            switch self {
            case .keyRepeat: try await Task.sleep(for: .milliseconds(30))
            case .nextTurn: await Task.yield()
            }
        }
    }

    /// When the closes start: once every tab is the daemon's and placed, or right after the last press.
    enum Closes: String, CaseIterable, Sendable { case settled, atOnce }

    /// The strip as names, one line per change: `a`, `b`, the new tabs `1 2 ...` by the order the strip first showed them
    /// (a stand-in `p`, the daemon's tab `d`), the selected one in brackets.
    @MainActor final class Frames {
        private var names: [String: String]
        private var seen = 0
        private(set) var lines: [String] = []
        init(a: String, b: String) { names = [a: "a", b: "b"] }

        func name(_ id: String) -> String {
            if let name = names[id] { return name }
            seen += 1
            let name = "\(ProvisionalTab.isProvisional(id) ? "p" : "d")\(seen)"
            names[id] = name
            return name
        }

        func sample(_ step: String, _ pane: PaneController, store: [String]) {
            let selected = pane.stripModel.selectedID?.rawValue
            let strip = pane.orderedIDs.map { $0.rawValue == selected ? "[\(name($0.rawValue))]" : name($0.rawValue) }.joined(separator: " ")
            let line = "\(strip)   | daemon: \(store.map(name).joined(separator: " "))"
            if lines.last?.hasSuffix(line) != true { lines.append("\(step): \(line)") }
        }

        var report: String { "\n" + lines.joined(separator: "\n") }
    }

    @Test(arguments: Kind.allCases, Gap.allCases)
    func aBurstOfNewTabsStaysInPressOrderAndClosesBackToItsStart(kind: Kind, gap: Gap) async throws {
        for closes in Closes.allCases {
            try await run(kind: kind, gap: gap, closes: closes)
        }
    }

    private func run(kind: Kind, gap: Gap, closes: Closes) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-burst-order")
            if kind == .page { try #require(services.agentTabs.canHostChat, "this build has no New Tab page") }
            let window = try #require(services.windows.active)
            let pane = try #require(window.focusedPane)
            let store = services.daemon.store
            let handle = pane.pane.handle
            window.window?.setFrame(NSRect(x: 100, y: 100, width: 1500, height: 700), display: true)
            @MainActor func daemonTabs() -> [String] { store.pane(handle)?.tabs.map(\.id) ?? [] }

            // `a b`: the pane's first terminal and a page after it; `a` selected.
            let a = try #require(pane.orderedIDs.first?.rawValue, "the pane has no first tab")
            let page = try await connection.newFrontendBrowserTab(url: "https://example.com/b", engine: .webkit, in: handle, activate: false)
            try await PasswordManagerRouteTests.until { store.tab(surface: page.surface).map { tab in pane.orderedIDs.contains { $0.rawValue == tab.id } } == true }
            let b = try #require(store.tab(surface: page.surface)).id
            pane.select(TabID(a))
            try #require(pane.stripModel.selectedID?.rawValue == a && pane.orderedIDs.map(\.rawValue) == [a, b],
                         "the pane does not start as [a] b: \(pane.orderedIDs.map(\.rawValue))")

            let frames = Frames(a: a, b: b)
            var wrong: [String] = []
            /// The strip is `a`, `count` new tabs, `b`, and the rightmost new tab (or `a`) is selected.
            @MainActor func check(_ step: String, new count: Int) {
                frames.sample(step, pane, store: daemonTabs())
                let strip = pane.orderedIDs.map(\.rawValue)
                guard strip.count == count + 2, strip.first == a, strip.last == b else {
                    return wrong.append("\(step): the strip is not a, \(count) new, b")
                }
                if pane.stripModel.selectedID?.rawValue != strip[count] { wrong.append("\(step): the selected tab is not the newest (place \(count))") }
            }

            let context = "\(kind.rawValue), \(gap.rawValue), closes \(closes.rawValue)"
            for press in 1...Self.presses {
                #expect(services.registry.perform(kind.action, invocation: ActionInvocation(origin: .user)), "press \(press) was refused (\(context))")
                check("press \(press)", new: press)
                try await gap.wait()
            }

            @MainActor func made() -> [String] { daemonTabs().filter { $0 != a && $0 != b && !ProvisionalTab.isProvisional($0) } }
            if closes == .settled {
                // Every tab is the daemon's, in its slot: the strip and the daemon agree, and no open is being placed.
                var order: [String] = []
                let deadline = ContinuousClock.now + .seconds(40)
                while ContinuousClock.now < deadline {
                    frames.sample("settle", pane, store: daemonTabs())
                    let strip = pane.orderedIDs.map(\.rawValue)
                    // A new tab the strip showed never changes its place among the new tabs it showed before.
                    let shown = strip.filter { $0 != a && $0 != b && !ProvisionalTab.isProvisional($0) }
                    let kept = order.filter(shown.contains)
                    if kept != shown.filter(order.contains) { wrong.append("settle: the new tabs changed their order") }
                    order = shown
                    if made().count == Self.presses, strip == daemonTabs(), !NewTabSuccession.isOpen(in: pane.pane),
                       !strip.contains(where: ProvisionalTab.isProvisional) { break }
                    try await Task.sleep(for: .milliseconds(15))
                }
                try #require(made().count == Self.presses && pane.orderedIDs.map(\.rawValue) == daemonTabs(),
                             "the burst did not settle (\(context)): \(frames.report)")
                // Past the opens' own deadlines: nothing reorders later.
                let quiet = ContinuousClock.now + .milliseconds(2500)
                while ContinuousClock.now < quiet {
                    check("quiet", new: Self.presses)
                    try await Task.sleep(for: .milliseconds(25))
                }
                #expect(daemonTabs().first == a && daemonTabs().last == b, "the daemon's order is not a, new tabs, b (\(context)): \(frames.report)")
            }

            // A held Cmd-W: each close selects the tab on the left of the closed one, the tab it was made from.
            for close in 1...Self.presses {
                let left = Self.presses - close
                let strip = pane.orderedIDs.map(\.rawValue)
                let expected = strip.indices.contains(left) ? strip[left] : nil
                #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)), "close \(close) was refused (\(context))")
                frames.sample("close \(close)", pane, store: daemonTabs())
                let now = pane.orderedIDs.map(\.rawValue)
                if now.count != left + 2 || now.first != a || now.last != b { wrong.append("close \(close): the strip is not a, \(left) new, b") }
                if pane.stripModel.selectedID?.rawValue != expected { wrong.append("close \(close): the selection did not go to the tab on the left") }
                try await gap.wait()
            }
            // The closes commit: the pane is `[a] b` and stays so.
            let end = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < end, daemonTabs() != [a, b] || pane.orderedIDs.map(\.rawValue) != [a, b] {
                frames.sample("closing", pane, store: daemonTabs())
                if pane.stripModel.selectedID?.rawValue == b { wrong.append("closing: b was selected"); break }
                try await Task.sleep(for: .milliseconds(15))
            }
            // A tab closed before the daemon made it is still made, then closed (its creation was sent after the one
            // before it): the pane is `a b` and stays so for a second.
            var rest = ContinuousClock.now + .seconds(1)
            while ContinuousClock.now < rest, ContinuousClock.now < end {
                frames.sample("end", pane, store: daemonTabs())
                if daemonTabs() != [a, b] { rest = ContinuousClock.now + .seconds(1) }
                if pane.orderedIDs.map(\.rawValue) != [a, b] { wrong.append("end: the strip showed a tab after the closes"); break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(daemonTabs() == [a, b], "the daemon's pane is not a b after the closes (\(context)): \(frames.report)")
            #expect(pane.orderedIDs.map(\.rawValue) == [a, b] && pane.stripModel.selectedID?.rawValue == a,
                    "the strip is not [a] b after the closes (\(context)): \(frames.report)")
            #expect(wrong.isEmpty, "\(context): \(wrong.prefix(12).joined(separator: "; ")) \(frames.report)")
        }
    }
}
