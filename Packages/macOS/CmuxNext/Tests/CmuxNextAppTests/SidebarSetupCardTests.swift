import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextOnboarding
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// First-run setup is a compact "Finish setting up" card docked at the sidebar's bottom left, not a card floating
/// over Home's chat (Lawrence msg 25425): a title with an x, a progress bar with "1 of N", a row per step
/// (done rows dimmed and inert) and one full-width button for the next step. A row's click runs its step, the x
/// hides setup for good, every nested corner is concentric with the card, and the rows come from the same
/// setup model the old card used, with no local-network note among them.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarSetupCardTests {
    static let card = SidebarSetupCard(
        title: "Finish setting up",
        steps: [SidebarSetupCard.Step(id: "agents", title: "Sign In to Claude Code", done: true),
                SidebarSetupCard.Step(id: "history", title: "Import Chat History"),
                SidebarSetupCard.Step(id: "account", title: "Sign In to cmux"),
                SidebarSetupCard.Step(id: "cli", title: "Install the cmux Command", runnable: false, help: "Another cmux command is on your PATH")],
        progressText: "1 of 4", buttonTitle: "Import Chat History", buttonStep: "history", closeLabel: "Hide Setup")

    struct Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        let sent: Box
        var card: SidebarSetupCardView { sidebar.setupCardView }

        func settle() async {
            let deadline = ContinuousClock.now + .seconds(5)
            // test-only: the sidebar follows its model on a task; bounded by the deadline.
            while card.isHidden || card.frame.isEmpty, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
                sidebar.needsLayout = true
                sidebar.layoutSubtreeIfNeeded()
            }
            sidebar.layoutSubtreeIfNeeded()
        }
    }

    final class Box { var intents: [SidebarIntent] = [] }

    func make(_ card: SidebarSetupCard? = SidebarSetupCardTests.card) async -> Harness {
        _ = NSApplication.shared
        let model = SidebarModel()
        let sent = Box()
        model.onIntent = { sent.intents.append($0) }
        model.setupCard = card
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: Metrics.sidebarWidth, height: 720), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: Metrics.sidebarWidth, height: 720)
        window.orderFrontRegardless()
        let h = Harness(model: model, sidebar: sidebar, window: window, sent: sent)
        await h.settle()
        return h
    }

    @Test func theCardDocksAtTheSidebarsBottomLeftWithARowPerStep() async throws {
        let h = await make()
        defer { h.window.close() }
        let card = h.card
        try #require(!card.isHidden && !card.frame.isEmpty, "no Finish setting up card in the sidebar")
        #expect(h.sidebar.bounds.contains(card.frame), "the card \(card.frame) is not inside the sidebar \(h.sidebar.bounds)")
        #expect(card.frame.minX == Metrics.space3, "the card is inset like the other bottom-left cards")
        #expect(card.frame.midY > h.sidebar.bounds.midY, "the card \(card.frame) is not docked at the bottom")
        #expect(card.titleLabel.stringValue == "Finish setting up")
        #expect(card.progressLabel.stringValue == "1 of 4")
        #expect(card.rows.map { $0.step?.title } == ["Sign In to Claude Code", "Import Chat History", "Sign In to cmux", "Install the cmux Command"])
        #expect(card.button.title == "Import Chat History" && !card.button.isHidden)
        #expect(!card.rows[0].isRunnable, "a done row takes no click")
        #expect(!card.rows[3].isRunnable, "a step cmux cannot run from here takes no click")
        #expect(card.rows[1].isRunnable && card.rows[2].isRunnable)
        for view in [card.titleLabel, card.progressLabel, card.closeButton, card.button] + card.rows as [NSView] {
            #expect(card.bounds.contains(view.frame) && !view.frame.isEmpty, "\(type(of: view)) at \(view.frame) is not on the card")
        }
        #expect(card.frame.height == SidebarSetupCardView.height(for: Self.card))
    }

    @Test func aRowTheButtonAndTheXSendTheirIntents() async throws {
        let h = await make()
        defer { h.window.close() }
        try #require(!h.card.isHidden)
        h.card.rows[2].press()
        h.card.rows[0].press() // done: nothing
        h.card.rows[3].press() // cannot run: nothing
        h.card.button.press()
        h.card.closeButton.onPress?()
        #expect(h.sent.intents == [.runSetupStep("account"), .runSetupStep("history"), .hideSetupCard])
    }

    /// a1050's rule: a nested corner is the outer one less the inset between them.
    @Test func everyNestedCornerIsConcentricWithTheCard() async throws {
        let h = await make()
        defer { h.window.close() }
        let card = h.card
        try #require(!card.isHidden)
        let outer = try #require(card.surface.layer?.cornerRadius)
        #expect(outer == Metrics.surfaceCornerRadius)
        let buttonInset = card.button.frame.minX
        #expect(card.button.layer?.cornerRadius == max(0, outer - buttonInset), "the button is not concentric with the card")
        let rowInset = card.rows[1].frame.minX
        #expect(card.rows[1].layer?.cornerRadius == Metrics.cornerRadius(insetFromSurface: rowInset, size: card.rows[1].frame.size),
                "a row's hover fill is not concentric with the card")
    }

    @Test func noCardWithoutUnfinishedSetupAndItLeavesWhenSetupEnds() async throws {
        let none = await make(nil)
        defer { none.window.close() }
        #expect(none.card.isHidden || none.card.frame.isEmpty, "a card shows with no setup to finish")

        let h = await make()
        defer { h.window.close() }
        try #require(!h.card.isHidden)
        h.model.setupCard = nil
        let deadline = ContinuousClock.now + .seconds(5)
        // test-only: waits out the card's exit, bounded by the deadline.
        while !h.card.isHidden, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            h.sidebar.needsLayout = true
            h.sidebar.layoutSubtreeIfNeeded()
        }
        #expect(h.card.isHidden, "the card stayed after setup ended")
    }

    /// The rows come from the setup model: agents, the chat history (found), the account and the command line,
    /// each click running its step; the local-network note is not a row. The button runs the first step a click
    /// can run, and every row done ends setup.
    @Test func theChecklistRunsEachStepFromTheSetupModel() async throws {
        let suite = "cmux-sidebar-setup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setup = FirstRunSetup(defaults: defaults)
        #expect(setup.begin(isFirstRun: true, replacedKeys: []))
        final class Log { var signIns = 0, imports = 0; var signedIn = false; var cli = "missing" }
        let log = Log()
        let model = SetupCardPageProvider(setup: setup, agents: nil, environment: SetupCardEnvironment(
            account: { (log.signedIn, log.signedIn ? "me@example.com" : nil) }, signInAccount: { log.signIns += 1 },
            cliState: { log.cli }, installCLI: { _ in }, openAgents: {}, screenReader: { false },
            historySources: { true }, importHistory: { log.imports += 1; return true }))
        defer { model.stop() }
        let deadline = ContinuousClock.now + .seconds(5)
        // test-only: the model's first reads (chat sources, PATH), bounded by the deadline.
        while model.history == nil || model.cli == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }

        #expect(model.checklist.map(\.kind) == [.agents, .history, .account, .cli])
        #expect(!model.checklist.contains { $0.title.localizedCaseInsensitiveContains("network") }, "the local-network note is not a step")
        let card = SidebarCardFeed.setupCard(model.checklist)
        #expect(card.title == "Finish setting up")
        #expect(card.progressText == "0 of 4")
        #expect(card.buttonStep == "history", "the button runs the first step a click can run (no agent is known yet)")

        model.perform(.account)
        #expect(log.signIns == 1)
        model.perform(.history)
        #expect(log.imports == 1 && setup.historyDone)
        #expect(model.checklist.first { $0.kind == .history }?.done == true)
        model.perform(.history)
        #expect(log.imports == 1, "a done step does not run again")
        #expect(SidebarCardFeed.setupCard(model.checklist).progressText == "1 of 4")
    }
}
