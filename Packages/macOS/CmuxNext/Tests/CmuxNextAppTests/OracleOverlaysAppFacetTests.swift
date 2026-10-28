#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextControl
import CmuxNextDesign
import CmuxNextFocusUI
import CmuxNextOracle
@testable import CmuxNextPalette
import CmuxNextTerminalFind
import Testing

/// The app's `overlays` facet reads the owners: the dialogs and toasts a window's overlay host
/// presents, in its drawing order (a tab dialog whose tab is hidden is not there), the palette's rows and selection,
/// the terminal's and the browser's find models, and the hover target through its owners' parsers. A
/// `debug.oracle.wait_for` on the stack wakes when a dialog opens. Run: `swift test --filter OracleOverlaysAppFacetTests`.
@MainActor @Suite(.serialized) struct OracleOverlaysAppFacetTests {
    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func dialogs() -> CmuxDialogCenter {
        CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: {}, isAppActive: { true }))
    }

    private static func spec(_ identifier: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: identifier, buttons: [CmuxDialogButton(id: "ok", title: "OK", role: .default)], identifier: identifier)
    }

    private static func hosted(_ window: NSWindow) -> [OracleOverlaysFacet.Hosted] {
        AppServices.oracleHosted(WindowOverlayHost.existingHost(for: window))
    }

    @Test func theAppListsTheFacetWithTheOwnersChangeSignal() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.overlays))
        #expect(facets.changes(.overlays) != nil)
    }

    /// The finding: nothing the stack reads was observable, so a wait for a dialog ended as a false Timeout. The
    /// overlay host's change signal wakes it.
    @Test func aWaitOnTheStackWakesWhenADialogOpens() async throws {
        _ = NSApplication.shared
        let feed = OverlayChangeFeed()
        let window = Self.window()
        defer { window.close() }
        // The App gives each main window's host its feed (WindowManager.makeController).
        WindowOverlayHost.host(for: window).changes = feed
        let (reads, read) = AsyncStream<Int>.makeStream()
        let facets = OracleFacets([OracleOverlaysFacet(hash: AppServices.oracleSHA256, changes: { feed.subscribe() }) {
            let reading = OracleOverlaysFacet.Reading(windows: [.init(window: "win_1", hosted: Self.hosted(window))])
            read.yield(reading.stack.count)
            return reading
        }])
        let condition = try OracleWaitCondition(params: ["pointer": "/overlays/stack/0/kind", "equals": "dialog", "maxMs": 10_000])
        let waiting = Task {
            try await OracleSettleControl.awaitCondition(condition, facets: facets, snapshots: ControlSnapshotStore(),
                                                         deadline: .now + .seconds(10))
        }
        for await count in reads {
            #expect(count == 0)
            break
        }
        let dialogs = Self.dialogs()
        let id = dialogs.present(Self.spec("test.window"), in: .window(window)) { _ in }
        defer { dialogs.dismiss(id) }
        let outcome = try await waiting.value
        #expect(outcome.satisfied)
        #expect(outcome.value == "dialog")
    }

    /// A window dialog is on its window's stack with its spec; the one queued behind it in the same scope is not
    /// until the first is answered.
    @Test func aWindowDialogIsOnItsWindowsStackWithItsSpec() throws {
        _ = NSApplication.shared
        let window = Self.window()
        defer { window.close() }
        let dialogs = Self.dialogs()
        let first = dialogs.present(Self.spec("test.first"), in: .window(window)) { _ in }
        let second = dialogs.present(Self.spec("test.second"), in: .window(window)) { _ in }
        defer { dialogs.dismiss(second) }
        let open = OracleOverlaysFacet.Reading(windows: [.init(window: "win_1", hosted: Self.hosted(window))])
        #expect(open.stack == [.init(.dialog, window: "win_1")])
        #expect(open.dialogSpecID == "test.first")

        #expect(dialogs.press(first, button: "ok"))
        let next = OracleOverlaysFacet.Reading(windows: [.init(window: "win_1", hosted: Self.hosted(window))])
        #expect(next.stack == [.init(.dialog, window: "win_1")])
        #expect(next.dialogSpecID == "test.second")
    }

    /// A tab's dialog is withdrawn while its tab is hidden (a tab switch): the center still lists it first in its
    /// scope (`visible`), but it is not on screen, so it is not on the stack and its spec is not reported.
    @Test func aTabDialogWhoseTabIsHiddenIsNotOnTheStack() throws {
        _ = NSApplication.shared
        let window = Self.window()
        defer { window.close() }
        let tab = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        try #require(window.contentView).addSubview(tab)
        let dialogs = Self.dialogs()
        let id = dialogs.present(Self.spec("test.tab"), in: .tab(tab)) { _ in }
        defer { dialogs.dismiss(id) }
        #expect(Self.hosted(window) == [.init(.dialog, name: "test.tab")])

        tab.isHidden = true
        #expect(dialogs.record(id)?.visible == true)
        let hidden = OracleOverlaysFacet.Reading(windows: [.init(window: "win_1", hosted: Self.hosted(window))])
        #expect(hidden.stack.isEmpty)
        #expect(hidden.dialogSpecID == nil)

        tab.isHidden = false
        #expect(Self.hosted(window) == [.init(.dialog, name: "test.tab")])
    }

    /// The refusal HUD's toast is `refusalHud`, any other toast `toast`, in the order they were shown.
    @Test func toastsAndTheRefusalHUDAreTheirKinds() {
        _ = NSApplication.shared
        let window = Self.window()
        defer { window.close() }
        let toasts = CmuxToastCenter()
        toasts.show(CmuxToast(id: RefusalHUD.toastID, message: "Nothing to close"), in: window)
        toasts.show(CmuxToast(id: "saved", message: "Saved"), in: window)
        #expect(Self.hosted(window).map(\.kind) == [.refusalHud, .toast])
    }

    /// The stack is the host's drawing order: overlays of one layer in the order they were presented (both
    /// orders), a modal dialog above them whenever it came, and nothing that passes clicks through (a tooltip).
    @Test func hostedOverlaysGoInTheHostsDrawingOrder() {
        _ = NSApplication.shared
        let first = Self.window(), second = Self.window()
        defer { [first, second].forEach { $0.close() } }
        func present(_ kind: OverlayOptions.Kind, on window: NSWindow) {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
            _ = WindowOverlayHost.host(for: window).present(view, options: OverlayOptions(kind: kind, passesThroughClicks: false))
        }
        present(.dialog, on: first)
        present(.popover, on: first)
        present(.menu, on: first)
        _ = WindowOverlayHost.host(for: first).present(NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20)),
                                                       options: .tooltip(at: NSRect(x: 10, y: 10, width: 1, height: 1)))
        #expect(Self.hosted(first).map(\.kind) == [.popover, .menu, .dialog])
        present(.menu, on: second)
        present(.popover, on: second)
        #expect(Self.hosted(second).map(\.kind) == [.menu, .popover])
    }

    /// The open palette's page, hashed query, first rows (a folder's path only as its hash) and selected index.
    @Test func thePaletteIsItsPageRowsAndSelection() async throws {
        _ = NSApplication.shared
        let palette = PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.hide() }
        let ids = ["action:split", "path:/Users/me/src", "tab:tab_9"]
        palette.model.reset(to: PalettePageSpec(
            id: "picker", title: "Folder", placeholder: "",
            providers: [StaticPaletteProvider(id: "rows", items: ids.map { id in
                PaletteItem(id: id, title: id, primary: PaletteCommand(id: "pick", title: "Pick", symbol: "return", effect: .perform {}))
            })],
            keepsSectionOrder: true))
        await palette.model.settle()
        #expect(AppServices.oraclePalette(open: false, palette.model) == .init())

        let reading = AppServices.oraclePalette(open: true, palette.model)
        #expect(reading.open)
        #expect(reading.mode == palette.model.currentPageID)
        #expect(reading.rowIDs == ids)
        #expect(reading.selectedIndex == 0)
        palette.model.handle(.moveDown)
        #expect(AppServices.oraclePalette(open: true, palette.model).selectedIndex == 1)

        let value = OracleOverlaysFacet.Reading(palette: reading).value(hash: AppServices.oracleSHA256)
        #expect(value["palette"]?["topIds"] == ["action:split", .string("path:" + AppServices.oracleSHA256("/Users/me/src")), "tab:tab_9"])
    }

    /// The terminal's find controller and the browser chrome's find model are the find bar: open, query, count
    /// and selected match.
    @Test func theFindModelsAreTheFindBar() {
        let terminal = TerminalFindController()
        #expect(AppServices.oracleFindBar(terminal, pane: "pane_1") == .init(open: false, pane: "pane_1"))
        terminal.open(seed: "error", takeFocus: false)
        terminal.receiveTotal(4)
        terminal.receiveSelected(2)
        #expect(AppServices.oracleFindBar(terminal, pane: "pane_1")
            == .init(open: true, pane: "pane_1", query: "error", matches: 4, selected: 2))

        let browser = BrowserFindModel()
        browser.isPresented = true
        browser.setQuery("cmux")
        browser.record(BrowserFindResult(matchFound: true, matchCount: 3, currentIndex: 2), for: "cmux")
        #expect(AppServices.oracleFindBar(browser, pane: "pane_2")
            == .init(open: true, pane: "pane_2", query: "cmux", matches: 3, selected: 1))
        // An answer for a query the person has typed past is not this query's.
        browser.setQuery("cmux2")
        browser.record(BrowserFindResult(matchFound: true, matchCount: 9, currentIndex: 9), for: "cmux")
        #expect(AppServices.oracleFindBar(browser, pane: "pane_2") == .init(open: true, pane: "pane_2", query: "cmux2"))
    }

    /// A hover target is the item its owner's parser names; a link chip (its target holds a URL) and a workspace
    /// with no public id are null.
    @Test func aHoverTargetIsItsOwnersItem() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.oracleHoverTarget(HoverTargetID("grp:grp_3")) == .group("grp_3"))
        #expect(services.oracleHoverTarget(HoverTargetID("tab:tab_9")) == .tab("tab_9"))
        #expect(services.oracleHoverTarget(HoverTargetID("ws:not-loaded")) == nil)
        #expect(services.oracleHoverTarget(HoverTargetID("rail:not-loaded")) == nil)
        #expect(services.oracleHoverTarget(HoverTargetID("homeChip:https://example.com/a")) == nil)
        #expect(services.oracleHoverTarget(HoverTargetID("sidebar:pull-requests")) == nil)
    }

    @Test func focusOverlaysHaveTheSchemasKinds() {
        #expect(AppServices.oracleKind(.palette) == .palette)
        #expect(AppServices.oracleKind(.sheet) == .sheet)
        #expect(AppServices.oracleKind(.groupEditor) == .popover)
        #expect(AppServices.oracleKind(.rename) == .popover)
    }

    @Test func typedTextIsItsSHA256() {
        #expect(AppServices.oracleSHA256("split") == "sha256:ad1a64057f9ab34fecfe3f4ee78660bb0316dbda9370581ffbeb1e8bddf3d598")
        #expect(AppServices.oracleSHA256("error") == "sha256:ca00fccfb408989eddc401062c4d1219a6aceb6b9b55412357f1790862e8f178")
    }
}
#endif
