import AppKit
@testable import CmuxNextApp
@testable import CmuxNextApps
import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHistory
import CmuxNextWakeups
import Foundation
import Testing

/// The page tabs that put their SwiftUI in a `VisibilityGatedHostingView` keep
/// working while the gate exists: a focused tab gives its SwiftUI the keyboard, a snapshot of a hidden
/// page draws the page, and a hide and show (which runs SwiftUI's appear handlers again) keeps what the
/// person typed, sends an app no `edit` it did not make, and reads nothing again.
@MainActor @Suite(.serialized) struct VisibilityGatedPagesTests {
    @MainActor struct Shown {
        let window: NSWindow
        let tab: VisibilityNode
        let app: VisibilityNode

        func pass() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func hideAndShow() {
            tab.set(.hidden)
            pass()
            tab.set(.visible)
            pass()
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    /// `content` as a window's content, its gate following a visible tab node.
    private static func show(_ content: NSView, gate: VisibilityGatedHostingView) -> Shown {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        let app = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", own: .visible, parent: app)
        gate.follow(tab, observations: nil)
        let shown = Shown(window: window, tab: tab, app: app)
        shown.pass()
        return shown
    }

    /// Selects all of `field`'s text and types `text` over it.
    private static func type(_ text: String, into field: NSTextField, in window: NSWindow) throws {
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    // MARK: Focus

    @Test func aFocusedGatedPageTabGivesItsSwiftUITheKeyboard() throws {
        let todo = try Self.todoPage(editing: nil)
        let gate = todo.gate
        let page = InternalPageView(key: "gated-focus", page: .workspaceTodo, content: gate)
        let shown = Self.show(page, gate: gate)
        defer { shown.close() }

        #expect(page.focusTarget === gate.hosting, "the hosting view takes the keyboard, not the container")
        #expect(shown.window.makeFirstResponder(page.focusTarget))
        let responder = try #require(shown.window.firstResponder as? NSView)
        #expect(responder.isDescendant(of: gate.hosting), "the keyboard is in the page: \(responder)")
    }

    // MARK: Snapshot

    @Test func aHiddenBookmarkManagerSnapshotsThePage() throws {
        let host = BookmarkManagerHostView(model: BookmarkManagerModel(source: nil))
        let gate = try #require(host.visibilityGate)
        let shown = Self.show(host, gate: gate)
        defer { shown.close() }

        shown.tab.set(.hidden)
        #expect(gate.isGated)
        let image = try #require(host.cachedDisplayImage(), "a hidden page draws for its hibernation picture")
        #expect(Self.inkedPoints(in: image) > 0, "the picture shows the page, not a blank")
        #expect(gate.isGated && gate.hosting.superview == nil, "the page stays out of the window after the picture")
    }

    // MARK: Body counts

    /// A content-init page (the counting root of HostingBodyCounter+SwiftUI.swift) counts its root's bodies into
    /// its gate and the ledger: at least one once shown, attributed to a shown node. (Model-driven bodies while
    /// hidden: TasksHostViewGateTests, where the pane's own views record.)
    @Test func aGatedPageCountsItsRootBodies() throws {
        let host = BookmarkManagerHostView(model: BookmarkManagerModel(source: nil))
        let gate = try #require(host.visibilityGate)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        let app = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", own: .visible, parent: app)
        let ledger = ObservationLedger()
        gate.follow(tab, observations: ledger)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        #expect(gate.bodyEvaluations.total >= 1, "the page's root counted its body once shown: \(gate.bodyEvaluations)")
        #expect(gate.bodyEvaluations.hidden == 0, "shown, not hidden: \(gate.bodyEvaluations)")
        let entry = try #require(ledger.snapshot(matching: "Hosting.BookmarkManagerHostView").first)
        #expect(entry.bodyEvaluations >= 1 && entry.hiddenBodyEvaluations == 0, "debug.observations: \(entry)")
    }

    /// Points on a 24 x 24 grid over `image` that are not fully clear.
    private static func inkedPoints(in image: CGImage) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        var inked = 0
        for row in 0..<24 {
            for column in 0..<24 {
                let x = column * image.width / 24, y = row * image.height / 24
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 { inked += 1 }
            }
        }
        return inked
    }

    // MARK: State kept across a hide and show

    /// The real Todo page (WorkspaceTodoPageService.makeView) of workspace `w1` and its checklist
    /// (WorkspaceChecklistTests.seed), with item `editing` in edit mode.
    private static func todoPage(editing: String?) throws -> (services: AppServices, gate: VisibilityGatedHostingView,
                                                                model: WorkspaceTodoPageModel) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        try WorkspaceChecklistTests.seed(services.machines.local.store)
        let key = LocalPageTab.makeKey(.workspaceTodo)
        let gate = try #require(services.workspaceTodo.makeView(for: key, in: nil) as? VisibilityGatedHostingView)
        let model = try #require(services.workspaceTodo.models[key])
        model.workspaceID = "w1"
        model.editing = editing
        #expect(model.items.count == 3, "the page lists the seeded checklist")
        return (services, gate, model)
    }

    @Test func aTodoItemBeingEditedKeepsItsTypedText() throws {
        let todo = try Self.todoPage(editing: "chk_a")
        let gate = todo.gate
        let shown = Self.show(gate, gate: gate)
        defer { shown.close() }
        // The page's fields: the new-item draft, then the edited item's text.
        let field = try #require(HomeSheetThemeTests.editableFields(in: gate.hosting).first { $0.stringValue == "read the issue" })
        try Self.type("read the whole issue", into: field, in: shown.window)
        shown.pass()

        shown.hideAndShow()
        let again = try #require(HomeSheetThemeTests.editableFields(in: gate.hosting).first { $0.stringValue != todo.model.draft })
        #expect(again.stringValue == "read the whole issue", "the typed edit stays: \(again.stringValue)")
        #expect(todo.model.editing == "chk_a", "a hide and show commits and ends no edit")
    }

    /// The app pane's dispatches.
    @MainActor private final class Dispatches: AppSceneInteraction {
        var events: [(node: String, event: String)] = []
        func dispatch(node: String, event: String, payload: AppJSON) { events.append((node, event)) }
        var edits: Int { events.filter { $0.event == "edit" }.count }
    }

    @Test func anAppTextFieldKeepsItsTextAndSendsNoEditOnShow() throws {
        let model = AppSceneModel()
        let dispatches = Dispatches()
        model.interaction = dispatches
        model.apply([.create(id: "name", type: "TextField", props: ["text": .string("start"), "onEdit": .bool(true)]), .root(id: "name")])
        let gate = VisibilityGatedHostingView(owner: "AppPanePage", hosting: AppSceneHostingView(
            model: model, bundleDirectory: nil, bundleImages: AppBundleImageCache()))
        let shown = Self.show(gate, gate: gate)
        defer { shown.close() }
        #expect(dispatches.edits == 0, "making the field sends no edit")
        let field = try #require(HomeSheetThemeTests.editableFields(in: gate.hosting).first)
        #expect(field.stringValue == "start")
        try Self.type("typed", into: field, in: shown.window)
        shown.pass()
        let typed = dispatches.edits

        shown.hideAndShow()
        #expect(dispatches.edits == typed, "a hide and show sends the app no edit: \(dispatches.events)")
        let again = try #require(HomeSheetThemeTests.editableFields(in: gate.hosting).first)
        #expect(again.stringValue == "typed", "the typed text stays: \(again.stringValue)")
    }

    /// Counts the vault's reads.
    @MainActor private final class CountingVaultSource: VaultSessionSource {
        private(set) var refreshes = 0
        func refresh() async { refreshes += 1 }
        func sessions() -> [AgentSession] { [] }
        func isLive(_ session: AgentSession) -> Bool { false }
    }

    @Test func theVaultPageReadsNothingOnAHideAndShow() async throws {
        let source = CountingVaultSource()
        let vault = SessionVault(source: source, work: BackgroundWork(), copyText: { _ in }, openURL: { _ in })
        let host = VaultHostView(vault: vault, registry: ActionRegistry(), readsOnAppear: false)
        let gate = try #require(host.visibilityGate)
        let shown = Self.show(host, gate: gate)
        defer { shown.close() }

        shown.hideAndShow()
        shown.hideAndShow()
        await Task.yield()
        #expect(source.refreshes == 0, "the page tab reads on show itself (VaultPageTab.setContentVisible), its view reads nothing")
    }

    @Test func theVaultSectionReadsWhenItAppears() {
        let source = CountingVaultSource()
        let vault = SessionVault(source: source, work: BackgroundWork(), copyText: { _ in }, openURL: { _ in })
        let host = VaultHostView(vault: vault, registry: ActionRegistry())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        let deadline = Date().addingTimeInterval(2)
        while source.refreshes == 0, Date() < deadline {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        #expect(source.refreshes == 1, "the right sidebar's section reads once it shows")
    }
}
