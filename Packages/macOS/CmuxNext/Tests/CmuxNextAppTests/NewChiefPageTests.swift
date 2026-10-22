import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
@testable import CmuxNextHome
import Testing

/// New Chief… opens its card as a page tab beside your work instead of a sheet over Home (Leo
/// 2026-10-21, "Chief: sheet as workspace"); `home.newChiefSheet` in Debug Settings brings the sheet
/// back for one release. Frame reads of the card in the tab, its close and create paths, and its keys.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct NewChiefPageTests {
    /// The page's host, recording what the page asked of the app.
    private final class Recorder {
        var closed: [String] = []
        var shown: [ConversationID] = []
        var created: [(String, ChiefBackend)] = []
        var outcome: HomeComposeOutcome = .opened(ConversationID("chief-2"))
        var onShow: (() -> Void)?

        var host: NewChiefPage.Host {
            NewChiefPage.Host(
                create: { [self] name, backend in
                    created.append((name, backend))
                    return outcome
                },
                close: { [self] key in closed.append(key) },
                show: { [self] id in
                    shown.append(id)
                    onShow?()
                })
        }
    }

    private static func page(_ page: NewChiefPage, key: String) throws -> HomeSheetPageView {
        try #require(page.makeView(for: key, in: nil) as? HomeSheetPageView, "the tab's view is the New Chief card's page")
    }

    @Test func newChiefOpensAsAPageUnlessTheDebugToggleKeepsTheSheet() {
        #expect(HomeTunables.newChiefSheet.descriptor.key == "home.newChiefSheet")
        #expect(HomeTunables.newChiefSheet.value == false, "the page tab is the default")
        #expect(HomeTunables.all.contains { $0.key == "home.newChiefSheet" }, "Debug Settings lists the toggle")
        #expect(NewChiefPage.opensAsPage(sheetToggle: false, classic: false, channels: false))
        #expect(!NewChiefPage.opensAsPage(sheetToggle: true, classic: false, channels: false), "the toggle keeps the sheet")
        #expect(!NewChiefPage.opensAsPage(sheetToggle: false, classic: true, channels: false), "classic Home keeps its sheet")
        #expect(!NewChiefPage.opensAsPage(sheetToggle: false, classic: false, channels: true), "Channels keeps its page route")
    }

    @Test func thePageIsTheNewChiefTab() throws {
        let page = NewChiefPage(host: Recorder().host)
        #expect(page.page == .newChief)
        #expect(page.page.rawValue == "new-chief")
        #expect(page.title == HomeConversationStrings.chiefTitle)
        let view = try Self.page(page, key: "local-page:new-chief:1")
        #expect(view.sheet is HomeNewChiefSheet)
        #expect(view.firstField?.accessibilityIdentifier() == "cmux.home.chief.name", "the name field is the page's first input")
        #expect(view.primaryInputView === view.firstField, "the tab's keyboard lands in the name field")
    }

    /// Frame reads: the card keeps its sheet width at the top of the pane, centered in a wide pane and
    /// from the leading edge in a narrow one, on a background that fills the pane.
    @Test func theCardSitsAtTheTopOfThePane() throws {
        let view = try Self.page(NewChiefPage(host: Recorder().host), key: "k")
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        view.layoutSubtreeIfNeeded()
        let card = view.sheet.view.frame
        #expect(card.width == 420, "the sheet's own width: \(card)")
        #expect(abs(card.midX - 500) < 0.5, "centered in a wide pane: \(card)")
        #expect(abs(card.maxY - (700 - HomeSheetPageView.topInset)) < 0.5, "at the top, below the inset: \(card)")
        #expect(card.minY > 0, "the whole card shows: \(card)")
        let background = try #require(view.subviews.first { $0 !== view.sheet.view })
        #expect(background.frame == view.bounds, "the background fills the pane: \(background.frame)")

        view.frame = NSRect(x: 0, y: 0, width: 360, height: 700)
        view.layoutSubtreeIfNeeded()
        #expect(view.sheet.view.frame.minX == 0, "a narrow pane shows the card from its leading edge: \(view.sheet.view.frame)")
    }

    @Test func cancelClosesTheTabAndShowsNothing() throws {
        let recorder = Recorder()
        let view = try Self.page(NewChiefPage(host: recorder.host), key: "k1")
        view.sheet.cancel(nil)
        #expect(recorder.closed == ["k1"])
        #expect(recorder.shown.isEmpty)
        #expect(recorder.created.isEmpty)
    }

    @Test func createMakesTheChiefClosesTheTabAndShowsItsConversation() async throws {
        let recorder = Recorder()
        let view = try Self.page(NewChiefPage(host: recorder.host), key: "k2")
        let sheet = try #require(view.sheet as? HomeNewChiefSheet)
        sheet.name.stringValue = "  Ops  "
        sheet.refreshPrimary()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            recorder.onShow = { done.resume() }
            sheet.primary(nil)
        }
        #expect(recorder.created.map(\.0) == ["Ops"])
        #expect(recorder.created.map(\.1) == [.claude])
        #expect(recorder.closed == ["k2"])
        #expect(recorder.shown == [ConversationID("chief-2")])
    }

    /// Closed while its create ran (Cmd-W): the Chief still shows, and no other tab is closed.
    @Test func aCreateThatEndsAfterItsTabClosedClosesNothing() async throws {
        let recorder = Recorder()
        let page = NewChiefPage(host: recorder.host)
        let view = try Self.page(page, key: "k3")
        let sheet = try #require(view.sheet as? HomeNewChiefSheet)
        sheet.name.stringValue = "Ops"
        sheet.refreshPrimary()
        page.tabClosed("k3")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            recorder.onShow = { done.resume() }
            sheet.primary(nil)
        }
        #expect(recorder.closed.isEmpty)
        #expect(recorder.shown == [ConversationID("chief-2")])
    }

    /// A refused create keeps the tab open and says why, as the sheet did.
    @Test func aRefusedCreateKeepsTheTab() async throws {
        let recorder = Recorder()
        recorder.outcome = .offline
        let view = try Self.page(NewChiefPage(host: recorder.host), key: "k4")
        let sheet = try #require(view.sheet as? HomeNewChiefSheet)
        sheet.name.stringValue = "Ops"
        sheet.refreshPrimary()
        sheet.primary(nil)
        for _ in 0..<200 where sheet.statusLabel.isHidden { await Task.yield() }
        #expect(!sheet.statusLabel.isHidden, "the card says why")
        #expect(recorder.closed.isEmpty)
        #expect(recorder.shown.isEmpty)
    }

    /// The card's Return and Escape are main-window key equivalents in a tab: they act only while the
    /// keyboard is in the page, so a terminal or chat beside it keeps them.
    @Test func theCardsKeysActOnlyWhileTheKeyboardIsInThePage() throws {
        let recorder = Recorder()
        let view = try Self.page(NewChiefPage(host: recorder.host), key: "k5")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))
        let beside = NSTextField(frame: NSRect(x: 1000, y: 10, width: 180, height: 24))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        root.addSubview(view)
        root.addSubview(beside)
        window.contentView = root
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))

        #expect(window.makeFirstResponder(beside))
        #expect(!view.ownsKeyboard)
        #expect(!view.performKeyEquivalent(with: escape), "Escape beside the page is not the card's")
        #expect(recorder.closed.isEmpty)
        #expect(view.primaryInputShouldTakeKeyboard(from: window.firstResponder), "focusing the tab moves the keyboard in")

        let field = try #require(view.firstField)
        #expect(window.makeFirstResponder(field))
        #expect(view.ownsKeyboard, "the name field (its field editor) is in the page")
        #expect(!view.primaryInputShouldTakeKeyboard(from: window.firstResponder), "a field inside the card keeps the keyboard")
    }
}
