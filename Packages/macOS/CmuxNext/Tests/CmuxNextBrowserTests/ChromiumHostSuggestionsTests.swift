import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// Task 061 of plans/cmux-next/chrome-parity/p01-process.md: a hosted page's autofill, password and
/// `<datalist>` suggestions in cmux's list. Chromium sends the rows (SUGGESTIONS SHOW) and moves the
/// selection with the field's keys (SELECT); the list draws them under the field, says SHOWN once
/// they are on screen, and answers the pointer as Chrome's popup view answers its controller: the
/// row under it, a click, a delete button, a click outside.
@MainActor
@Suite struct ChromiumHostSuggestionsTests {
    /// Records each answer; `browser` is the shown tab's.
    final class Recorder: ChromiumHostSuggestionWire {
        var suggestionBrowser: Int32?
        var sent: [String] = []

        init(browser: Int32? = 7) {
            suggestionBrowser = browser
        }

        func send(_ action: ChromiumHostSuggestionAction, token: Int64, row: Int, browser: Int32) {
            sent.append("\(action) \(token) \(row) \(browser)")
        }
    }

    /// Draws nothing: records what the list asked for and reports the pointer when a test says so.
    final class Presenter: ChromiumHostSuggestionPresenting {
        var onHover: ((Int?) -> Void)?
        var onPick: ((Int) -> Void)?
        var onRemove: ((Int) -> Void)?
        var onDismiss: (() -> Void)?
        var presents = true
        private(set) var presented: [(token: Int64, highlighted: Int?, field: CGRect)] = []
        private(set) var highlighted: Int?
        private(set) var isShown = false

        func present(_ suggestions: ChromiumHostSuggestions, highlighted: Int?, field: CGRect, in window: NSWindow) -> Bool {
            guard presents else { return false }
            presented.append((suggestions.token, highlighted, field))
            self.highlighted = highlighted
            isShown = true
            return true
        }

        func highlight(_ row: Int?) { highlighted = row }
        func hide() { isShown = false }
        var shownFrame: CGRect? { isShown ? CGRect(x: 1, y: 2, width: 3, height: 4) : nil }

        /// A dismiss rule closed it (a click outside).
        func dismissByRule() {
            isShown = false
            onDismiss?()
        }
    }

    /// The shim's JSON for a password field (CEFShim/tests/suggestion_rows_test.cpp's rows): an entry,
    /// a separator and a footer.
    static let passwordJSON = """
        {"x":10,"y":20,"width":240,"height":32,"rtl":false,"selected":-1,"rows":[\
        {"kind":0,"type":21,"main":"ada@example.com","minor":"","label":"•••","voice_over":"","selectable":true,"acceptable":true,"loading":false},\
        {"kind":1,"type":4,"main":"","minor":"","label":"","voice_over":"","selectable":false,"acceptable":false,"loading":false},\
        {"kind":3,"type":26,"main":"Manage passwords…","minor":"","label":"","voice_over":"","selectable":true,"acceptable":true,"loading":false}]}
        """

    static func row(_ kind: ChromiumHostSuggestions.Row.Kind, type: Int = 0, main: String = "alpha", selectable: Bool = true,
                    acceptable: Bool = true) -> ChromiumHostSuggestions.Row {
        .init(kind: kind, type: type, main: main, minor: "", labels: [], voiceOver: "", selectable: selectable, acceptable: acceptable,
              loading: false)
    }

    /// An autocomplete entry (removable), a title, a password entry (not removable) and a separator.
    static func rows(token: Int64 = 41, selected: Int? = nil) -> ChromiumHostSuggestions {
        ChromiumHostSuggestions(token: token, field: CGRect(x: 10, y: 20, width: 100, height: 30), selected: selected, rows: [
            row(.entry, type: ChromiumHostSuggestions.Row.autocompleteEntry),
            row(.title, main: "Saved", acceptable: false),
            row(.entry, type: 21, main: "ada"),
            row(.separator, type: 4, main: "", selectable: false, acceptable: false),
        ])
    }

    /// A page view 300 pt tall in a window whose content starts at (100, 100) on the screen.
    static func pageView() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: .borderless, backing: .buffered,
                              defer: true)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(view)
        return (window, view)
    }

    // MARK: The event

    @Test func theShowRowsDecodeFromTheShimsJSON() throws {
        let suggestions = try #require(ChromiumHostSuggestions(token: 41, json: Self.passwordJSON))
        #expect(suggestions.token == 41)
        #expect(suggestions.field == CGRect(x: 10, y: 20, width: 240, height: 32))
        #expect(suggestions.selected == nil, "-1 is no selection")
        #expect(suggestions.rows.map(\.kind) == [.entry, .separator, .footer])
        #expect(suggestions.rows[0].labels == ["•••"])
        #expect(suggestions.rows[0].accessibilityLabel == "ada@example.com, •••")
        #expect(!suggestions.rows[0].removable, "Chrome's delete button is on autocomplete entries only")
        #expect(ChromiumHostSuggestions(token: 1, json: "{\"x\":1}") == nil, "JSON the shim never writes")
    }

    @Test func labelLinesSplitAndAVoiceOverTextWins() throws {
        let json = """
            {"x":0,"y":0,"width":1,"height":1,"rtl":true,"selected":0,"rows":[\
            {"kind":0,"type":1,"main":"Ada","minor":"Lovelace","label":"1 Main St\\nLondon","voice_over":"Ada at home",\
            "selectable":true,"acceptable":true,"loading":false}]}
            """
        let suggestions = try #require(ChromiumHostSuggestions(token: 2, json: json))
        #expect(suggestions.rightToLeft)
        #expect(suggestions.selected == 0)
        #expect(suggestions.rows[0].labels == ["1 Main St", "London"])
        #expect(suggestions.rows[0].accessibilityLabel == "Ada at home")
    }

    @Test func suggestionsEventsDecodeAsPageViewEvents() throws {
        let rows = try #require(ChromiumHostSuggestions(token: 41, json: Self.passwordJSON))
        #expect(CEFShimEvent(kind: 60, browser: 7, request: 0, a: 41, b: 0, s1: Self.passwordJSON, s2: "") == .pageView(browser: 7, .suggestions(.show(rows))))
        #expect(CEFShimEvent(kind: 60, browser: 7, request: 1, a: 41, b: 2, s1: "", s2: "") == .pageView(browser: 7, .suggestions(.select(token: 41, row: 2))))
        #expect(CEFShimEvent(kind: 60, browser: 7, request: 1, a: 41, b: -1, s1: "", s2: "") == .pageView(browser: 7, .suggestions(.select(token: 41, row: nil))))
        #expect(CEFShimEvent(kind: 60, browser: 7, request: 2, a: 41, b: 0, s1: "", s2: "") == .pageView(browser: 7, .suggestions(.hide(token: 41))))
        #expect(CEFShimEvent(kind: 60, browser: 7, request: 3, a: 0, b: 0, s1: "Filled", s2: "") == .pageView(browser: 7, .suggestions(.announce("Filled"))))
        #expect(CEFShimEvent(kind: 60, browser: 7, request: 9, a: 0, b: 0, s1: "", s2: "") == .unknown(kind: 60))
        #expect(CEFShimEvent(kind: 60, browser: 7, request: 0, a: 1, b: 0, s1: "not json", s2: "") == .unknown(kind: 60))
        #expect(CEFShimEvent(kind: 60, browser: 7, request: 2, a: 41, b: 0, s1: "", s2: "").browserID == 7)
    }

    // MARK: The list

    @Test func shownRowsSitAtTheFieldAndSayShown() throws {
        let (window, view) = Self.pageView()
        let presenter = Presenter()
        let list = ChromiumHostSuggestionList(view: view, presenter: presenter)
        let wire = Recorder()
        list.handle(.show(Self.rows(selected: 2)), browser: 7, wire: wire)
        #expect(wire.sent == ["shown 41 0 7"])
        #expect(list.shown?.highlighted == 2)
        #expect(presenter.highlighted == 2, "a key opened them: Chromium's selection shows")
        // The field (10, 20) from the top left of a 300 pt view: y 250 from the bottom, then the window's origin.
        #expect(presenter.presented.first?.field == CGRect(x: 110, y: 350, width: 100, height: 30))
        #expect(list.fieldOnScreen == CGRect(x: 110, y: 350, width: 100, height: 30))
        #expect(list.report?.kinds == ["entry", "title", "entry", "separator"])
        withExtendedLifetime(window) {}
    }

    @Test func rowsOfATabNotShownAreDismissedAtOnce() {
        let (window, view) = Self.pageView()
        let presenter = Presenter()
        let list = ChromiumHostSuggestionList(view: view, presenter: presenter)
        let wire = Recorder(browser: 8)
        list.handle(.show(Self.rows()), browser: 7, wire: wire)
        #expect(wire.sent == ["dismiss 41 0 7"])
        #expect(presenter.presented.isEmpty)
        #expect(list.shown == nil)

        // A page view in no window cannot show them either.
        let alone = ChromiumHostSuggestionList(view: NSView(), presenter: presenter)
        let shown = Recorder()
        alone.handle(.show(Self.rows(token: 5)), browser: 7, wire: shown)
        #expect(shown.sent == ["dismiss 5 0 7"])
        withExtendedLifetime(window) {}
    }

    @Test func theFieldsKeysMoveTheHighlightOfTheShownTokenOnly() {
        let (window, view) = Self.pageView()
        let presenter = Presenter()
        let list = ChromiumHostSuggestionList(view: view, presenter: presenter)
        let wire = Recorder()
        list.handle(.show(Self.rows()), browser: 7, wire: wire)
        list.handle(.select(token: 41, row: 2), browser: 7, wire: wire)
        #expect(presenter.highlighted == 2)
        list.handle(.select(token: 40, row: 0), browser: 7, wire: wire)
        list.handle(.select(token: 41, row: 0), browser: 9, wire: wire)
        #expect(presenter.highlighted == 2, "an old token's or another browser's selection changes nothing")
        list.handle(.select(token: 41, row: nil), browser: 7, wire: wire)
        #expect(presenter.highlighted == nil)
        #expect(wire.sent == ["shown 41 0 7"], "Chromium moved it: nothing goes back")
        withExtendedLifetime(window) {}
    }

    @Test func thePointerSelectsClicksAcceptAndTheDeleteButtonRemoves() {
        let (window, view) = Self.pageView()
        let presenter = Presenter()
        let list = ChromiumHostSuggestionList(view: view, presenter: presenter)
        let wire = Recorder()
        list.handle(.show(Self.rows()), browser: 7, wire: wire)
        presenter.onHover?(0)
        presenter.onHover?(0)
        presenter.onHover?(3)
        presenter.onHover?(nil)
        presenter.onPick?(0)
        presenter.onPick?(1)
        presenter.onRemove?(0)
        presenter.onRemove?(2)
        #expect(wire.sent == ["shown 41 0 7", "select 41 0 7", "select 41 -1 7", "accept 41 0 7", "remove 41 0 7"],
                "one select per row reached, the separator is none, a title takes no click, a password entry has no delete button")
        #expect(presenter.highlighted == nil)
        withExtendedLifetime(window) {}
    }

    @Test func aClickOutsideDismissesAndHideOrANewShowEndsTheRows() {
        let (window, view) = Self.pageView()
        let presenter = Presenter()
        let list = ChromiumHostSuggestionList(view: view, presenter: presenter)
        let wire = Recorder()
        list.handle(.show(Self.rows()), browser: 7, wire: wire)
        presenter.dismissByRule()
        #expect(list.shown == nil)
        #expect(wire.sent.last == "dismiss 41 0 7")
        // Chromium's HIDE for the dismissed token after it: nothing more.
        list.handle(.hide(token: 41), browser: 7, wire: wire)
        #expect(wire.sent.count == 2)

        list.handle(.show(Self.rows(token: 42)), browser: 7, wire: wire)
        list.handle(.show(Self.rows(token: 43)), browser: 7, wire: wire)
        #expect(list.shown?.suggestions.token == 43, "a new show replaces the rows and their token")
        #expect(wire.sent.suffix(2) == ["shown 42 0 7", "shown 43 0 7"])
        list.handle(.hide(token: 42), browser: 7, wire: wire)
        #expect(presenter.isShown, "the replaced token's HIDE does not close the new rows")
        list.handle(.hide(token: 43), browser: 7, wire: wire)
        #expect(!presenter.isShown)
        #expect(list.shown == nil)
        withExtendedLifetime(window) {}
    }

    @Test func rowsThatCannotShowAreDismissedAndTheHostsEndClosesWithoutAnswers() {
        let (window, view) = Self.pageView()
        let presenter = Presenter()
        let list = ChromiumHostSuggestionList(view: view, presenter: presenter)
        let wire = Recorder()
        presenter.presents = false
        list.handle(.show(Self.rows()), browser: 7, wire: wire)
        #expect(wire.sent == ["dismiss 41 0 7"])

        presenter.presents = true
        list.handle(.show(Self.rows(token: 50)), browser: 7, wire: wire)
        list.hostEnded()
        #expect(!presenter.isShown)
        #expect(list.shown == nil)
        #expect(wire.sent == ["dismiss 41 0 7", "shown 50 0 7"], "a dead host is answered nothing")
        presenter.onHover?(0)
        presenter.onPick?(0)
        #expect(wire.sent.count == 2)
        withExtendedLifetime(window) {}
    }

    @Test func rowsCloseWhenTheirBrowserLeavesThePageView() {
        let (window, view) = Self.pageView()
        let presenter = Presenter()
        let list = ChromiumHostSuggestionList(view: view, presenter: presenter)
        let wire = Recorder()
        list.handle(.show(Self.rows()), browser: 7, wire: wire)
        list.shownBrowserChanged(to: 7) { _ in true }
        #expect(presenter.isShown, "the rows' own browser shown again keeps them")

        // The pane shows browser 8 (another tab, or 7 moved to another pane): 7's rows close, and Chromium hears it.
        list.shownBrowserChanged(to: 8) { _ in true }
        #expect(!presenter.isShown)
        #expect(list.shown == nil)
        #expect(wire.sent == ["shown 41 0 7", "dismiss 41 0 7"])
        // The HIDE that follows, sent to the pane 7 went to, finds nothing here.
        list.handle(.hide(token: 41), browser: 7, wire: wire)
        #expect(wire.sent.count == 2)

        // The tab closed: its rows close, and a gone browser is answered nothing.
        list.handle(.show(Self.rows(token: 42)), browser: 7, wire: wire)
        list.shownBrowserChanged(to: nil) { _ in false }
        #expect(!presenter.isShown)
        #expect(list.shown == nil)
        #expect(wire.sent == ["shown 41 0 7", "dismiss 41 0 7", "shown 42 0 7"])
        presenter.onPick?(0)
        #expect(wire.sent.count == 3, "clicks on closed rows send nothing")
        withExtendedLifetime(window) {}
    }

    // MARK: The rows

    @Test func theRowsViewDrawsEachKindAndOnlyAutocompleteEntriesHaveADeleteButton() throws {
        var picked: [Int] = []
        var removed: [Int] = []
        let rowsView = ChromiumHostSuggestionRows(onHover: { _ in }, onPick: { picked.append($0) }, onRemove: { removed.append($0) })
        let rows = Self.rows().rows
        rowsView.update(rows, highlighted: 2)
        let style = PopupStyle.standard
        let expected = 2 * style.padding + style.rowHeight + ChromiumHostSuggestionRows.titleHeight + style.rowHeight
            + ChromiumHostSuggestionRows.separatorHeight
        #expect(rowsView.contentHeight == expected)
        #expect(rowsView.rowViews.count == 4)
        let entry = try #require(rowsView.rowViews[0] as? PopupRowView)
        let password = try #require(rowsView.rowViews[2] as? PopupRowView)
        #expect(!(rowsView.rowViews[3] is PopupRowView), "a separator is a hairline")
        #expect(password.isHighlighted)
        #expect(!entry.isHighlighted)
        let button = try #require(entry.trailingView as? NSButton)
        #expect(button.accessibilityLabel() == Strings.suggestionRemove)
        #expect(password.trailingView == nil)
        _ = (button.target as? NSObject)?.perform(button.action, with: button)
        entry.onActivate?()
        #expect(removed == [0])
        #expect(picked == [0])

        rowsView.highlight(0)
        #expect(entry.isHighlighted && !password.isHighlighted)
        #expect(rowsView.accessibilityRole() == .list)
        #expect(rowsView.accessibilityChildren()?.count == 3, "the hairline is not a row for VoiceOver")
    }

    // MARK: The pane

    /// With no page view to draw them on, the pane dismisses the rows at once through the shim.
    @Test func aPaneWithoutAPageViewDismissesTheRows() throws {
        SuggestionSpy.calls = []
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-suggestions-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(SuggestionSpy.symbol), storage: CEFProfileStorage(root: root))
        // A pane's scheduled work reads the runtime through an unowned reference.
        _ = Unmanaged.passRetained(runtime)
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        #expect(host.hostedPageView == nil)
        host.pageViewChanged(.suggestions(.show(Self.rows(token: 77))), browser: 7)
        host.pageViewChanged(.suggestions(.hide(token: 77)), browser: 7)
        #expect(SuggestionSpy.calls == ["7 77 4 0"])
        #expect(CEFPaneSuggestionWire(pane: host).suggestionBrowser == nil, "in process: the rows never come to cmux")
    }

    /// The feature alone does not send the rows to cmux: below fork API 31 Chromium still draws them
    /// (a `<datalist>` as a hosted page popup), so the pane answers nothing and `debug.cef` reports null.
    @Test func cmuxDrawsTheRowsOnlyWithTheFeatureAndAForkThatSendsThem() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-suggestions-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { SuggestionSpy.forkAPI = 0 }
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(SuggestionSpy.symbol), storage: CEFProfileStorage(root: root))
        // A pane's scheduled work reads the runtime through an unowned reference.
        _ = Unmanaged.passRetained(runtime)
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        SuggestionSpy.forkAPI = CEFShimSuggestionOps.forkAPI
        #expect(!runtime.drawsSuggestionsInCmux, "in process")

        runtime.adoptHost(SilentSuggestionHost(), drawsSuggestions: true)
        SuggestionSpy.forkAPI = CEFShimSuggestionOps.forkAPI - 1
        #expect(!runtime.drawsSuggestionsInCmux, "the fork's popup still draws them")
        #expect(CEFPaneSuggestionWire(pane: host).suggestionBrowser == nil)

        SuggestionSpy.forkAPI = CEFShimSuggestionOps.forkAPI
        #expect(runtime.drawsSuggestionsInCmux)
    }
}

/// Stand-in shim functions: the suggestion action records itself; every other function does
/// nothing and returns 0.
private nonisolated enum SuggestionSpy {
    // crash-allow: only aPaneWithoutAPageViewDismissesTheRows reads and writes it, synchronously on the main actor
    nonisolated(unsafe) static var calls: [String] = []
    // crash-allow: only the suite's main-actor tests set it, and the runtime reads it on the same actor
    nonisolated(unsafe) static var forkAPI: Int32 = 0

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let action: @convention(c) (Int32, Int64, Int32, Int32) -> Int32 = { browser, token, action, index in
            SuggestionSpy.calls.append("\(browser) \(token) \(action) \(index)")
            return 1
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { SuggestionSpy.forkAPI }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_browser_suggestion_action": unsafeBitCast(action, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}

/// A host supervisor that never attaches: the runtime is in host mode and never starts.
@MainActor private final class SilentSuggestionHost: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}
