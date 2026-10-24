import AppKit
import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A New Tab page (an agent page with no session, in Chromium by default) that nobody sees freezes
/// after the hibernation's grace (perf-lead.md F3, PATTERNS.md P10). The host keeps pushing its
/// state to it: the open tabs and workspaces (NewTabPlacesFeed, on every terminal title, URL or
/// folder change in any workspace), the weather reading, and the user's `registry.js`. A push of
/// the host's state never thaws a frozen page: it waits, folded to the newest per kind, and goes
/// at the thaw. Before, these went as host scripts (`evaluateScript`), and each one thawed the page
/// and restarted its grace, so a hidden New Tab page never stayed frozen while anything changed.
@Suite(.serialized)
@MainActor
struct AgentPaneNewTabFrozenPushTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Records what a page reports to the freeze policy; freezes nothing by itself (the test calls
    /// ``PageWebView/freezeWhileHidden()`` as the policy would once the grace ends).
    private final class RecordingFreezePolicy: PageFreezePolicy {
        var woke = 0
        func hiddenPageWoke(_ page: PageWebView) { woke += 1 }
        func pageIsNoLongerHidden(_ page: PageWebView) {}
    }

    /// The envelopes the router sent to the page, in order.
    private final class Sent {
        var envelopes: [JSONValue] = [] { didSet { onSend?() } }
        var onSend: (() -> Void)?

        /// The `value` of every host event of `kind` the page got.
        func hostEvents(_ kind: String) -> [JSONValue] {
            envelopes.compactMap { envelope in
                guard envelope["data"]?["kind"]?.stringValue == kind else { return nil }
                return envelope["data"]?["value"] ?? .null
            }
        }
    }

    private let stage = PageTestWindow()

    /// A New Tab page in Chromium, started, booted, subscribed to the host's events, hidden and
    /// frozen; its router's envelopes go to `sent`.
    private func frozenNewTab(_ sent: Sent) async throws -> (AgentPaneView, PageWebView, FakeChromiumPage, NSView) {
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting(freezePolicy: RecordingFreezePolicy())
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), pageHost: true,
                                              chromium: hosting))
        view.model.becomeNewTab(AgentPaneNewTab(kind: .agent))
        let page = try #require(view.page)
        // The page's start ends with its document's load (PageWebView+Chromium.swift attachChromium).
        let pane = stage.show(NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)))
        view.frame = pane.bounds
        let started = await waitUntil("the Chromium page's start", { hosting.made.first?.loaded.isEmpty == false }) { check in
            hosting.onMade = { fake in fake.onLoad = { _ in check() } }
            pane.addSubview(view)
        }
        #expect(started)
        let fake = try #require(hosting.made.first)
        #expect(page.showsChromium)
        page.router.sendWithDrop = { envelope, _ in sent.envelopes.append(envelope) }
        pane.isHidden = true
        _ = await page.router.handle(["t": "booted"])
        let reply = await page.router.handle(["t": "sub", "id": 1, "stream": .string(AgentPageProvider.hostEvents)])
        #expect(reply["t"]?.stringValue == "ok")
        // The subscriber's replay (theme, shortcuts, ...) goes in one batch after the reply; a push
        // made before it went would queue behind it in the provider, not reach the router.
        let replayed = await waitUntil("the host events' replay", { !sent.hostEvents("shortcuts").isEmpty }) { check in
            sent.onSend = check
        }
        #expect(replayed)
        sent.onSend = nil
        #expect(page.freezeWhileHidden())
        #expect(fake.freezes == [true])
        return (view, page, fake, pane)
    }

    /// One wait that ends when `condition` holds, checked each time `observe`'s hook runs.
    private final class Wait {
        var resume: ((Bool) -> Void)?

        func finish(_ value: Bool) {
            resume?(value)
            resume = nil
        }
    }

    /// Runs `observe` with a hook that checks `condition`, and returns once it holds: true then,
    /// false (with an issue) when it has not held after 10 s. The bound only ends the wait of a
    /// broken build; the condition's own signal (the hook) ends a passing one.
    private func waitUntil(_ stage: String, _ condition: @escaping () -> Bool,
                           observe: (@escaping () -> Void) -> Void) async -> Bool {
        let wait = Wait()
        let held = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            wait.resume = { continuation.resume(returning: $0) }
            observe { if condition() { wait.finish(true) } }
            if condition() { wait.finish(true) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                wait.finish(false)
            }
        }
        if !held { Issue.record("\(stage) did not happen within 10 s") }
        return held
    }

    private func places(_ count: Int) -> [AgentPaneOmnibar.Tab] {
        (0..<count).map { AgentPaneOmnibar.Tab(id: "tab-\($0)", kind: .terminal, title: "zsh \($0)") }
    }

    @Test func placesRefreshesWhileFrozenThawNothingAndTheNewestGoesAtTheThaw() async throws {
        let sent = Sent()
        let (view, page, fake, pane) = try await frozenNewTab(sent)
        defer { view.close() }

        for count in 1...20 {
            view.refreshNewTabPlaces(tabs: places(count), workspaces: [AgentPaneOmnibar.Workspace(id: "w", name: "Work")])
        }
        #expect(fake.freezes == [true], "a places push thawed the hidden New Tab page")
        #expect(page.isChromiumFrozen)
        #expect(sent.hostEvents("newTabPlaces").isEmpty, "a places event went into the frozen page")

        pane.isHidden = false
        let delivered = sent.hostEvents("newTabPlaces")
        #expect(delivered.count == 1)
        #expect(delivered.first?["tabs"]?.arrayValue?.count == 20)
        #expect(delivered.first?["workspaces"]?.arrayValue?.count == 1)
    }

    @Test func weatherRefreshesWhileFrozenThawNothingAndTheNewestGoesAtTheThaw() async throws {
        let sent = Sent()
        let (view, page, fake, pane) = try await frozenNewTab(sent)
        defer { view.close() }

        for degrees in 10...19 {
            view.refreshNewTabWeather(AgentPaneNewTabWeather(place: "Berlin", temperature: Double(degrees), high: 21, low: 9,
                                                             code: 2, unit: "celsius", readAt: Date(timeIntervalSince1970: Double(degrees))))
        }
        #expect(fake.freezes == [true], "a weather push thawed the hidden New Tab page")
        #expect(page.isChromiumFrozen)

        pane.isHidden = false
        let delivered = sent.hostEvents("newTabWeather")
        #expect(delivered.count == 1)
        #expect(delivered.first?["temperature"]?.doubleValue == 19)

        // The widget turned off while the page shows: nil takes the reading away.
        view.refreshNewTabWeather(nil)
        #expect(sent.hostEvents("newTabWeather").last == .null)
    }

    /// The user's `registry.js` (and the rest of the customization) edited while the page is
    /// frozen: the page stays frozen, and the newest registry runs in it once, at the thaw.
    @Test func aRegistryEditWhileFrozenThawsNothingAndRunsOnceAtTheThaw() async throws {
        let sent = Sent()
        let (view, page, fake, pane) = try await frozenNewTab(sent)
        defer { view.close() }

        for edit in 1...5 {
            view.customization = AgentPaneCustomization(themeCSS: "body { --edit: \(edit); }", registryJS: "window.__registryEdit = \(edit);")
        }
        #expect(fake.freezes == [true], "a registry.js push thawed the hidden New Tab page")
        #expect(page.isChromiumFrozen)

        let ran = await waitUntil("the registry at the thaw", {
            fake.calls.contains { ($0.params["expression"] as? String)?.contains("__registryEdit = 5") == true }
        }) { check in
            fake.onCall = check
            pane.isHidden = false
        }
        #expect(ran)
        let registryRuns = fake.calls.filter { ($0.params["expression"] as? String)?.contains("__registryEdit") == true }
        #expect(registryRuns.count == 1, "the thaw ran \(registryRuns.count) registry scripts; only the newest should run")
        let customizations = sent.hostEvents("customization")
        #expect(customizations.last?["themeCSS"]?.stringValue == "body { --edit: 5; }")
    }
}
