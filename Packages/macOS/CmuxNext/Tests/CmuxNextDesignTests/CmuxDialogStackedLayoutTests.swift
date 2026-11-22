import AppKit
import CmuxNextDesignTokens
@testable import CmuxNextDesign
import Testing

/// A request with several ways to say yes (Lawrence 2026-11-17, a device asking to control this Mac: "improve this UI,
/// think liquid glass"): every answer the card's width, one under another, the default first with its Return keycap,
/// the other answers under it, and the cancel answer last as quiet red text with its Escape keycap; a code to compare
/// on an inset well; a failed answer in the danger ink. The card is the one cmux dialog card on its glass.
@MainActor
struct CmuxDialogStackedLayoutTests {
    static let spec = CmuxDialogSpec(
        title: "iPhone wants to control this Mac", lines: ["Asks for Full Control."],
        fields: [.code(label: "Device key fingerprint", text: "78BE 18E0 C08C 9C4D\n7443 D95E 2DB6 8074")],
        buttons: [
            CmuxDialogButton(id: "once", title: "Allow Once", role: .default),
            CmuxDialogButton(id: "alwaysView", title: "Always Allow View Only"),
            CmuxDialogButton(id: "alwaysFull", title: "Always Allow Full Control"),
            CmuxDialogButton(id: "deny", title: "Deny", role: .cancel),
        ],
        identifier: "test.stacked", layout: .stacked, error: "The answer did not reach the device hub. Try again.")

    static func laidOut(_ spec: CmuxDialogSpec = spec) -> (CmuxDialogView, NSWindow) {
        let view = CmuxDialogView(dialog: CmuxDialogPresentation(id: 1, spec: spec, activeLook: nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        window.contentView?.layoutSubtreeIfNeeded()
        return (view, window)
    }

    /// Top to bottom: Allow Once, Always Allow View Only, Always Allow Full Control, Deny; each the same width, left
    /// edges aligned, the same height, one gap apart. Before, Deny and Allow Once sat on one line at their own widths
    /// and the two Always Allow buttons on a second line at theirs.
    @Test func everyAnswerIsTheCardsWidthOneUnderAnother() throws {
        let (view, window) = Self.laidOut()
        defer { window.close() }
        let ids = ["once", "alwaysView", "alwaysFull", "deny"]
        let frames = try ids.map { id in
            let button = try #require(view.buttonView(id), "\(id)")
            return button.convert(button.bounds, to: nil)
        }
        for frame in frames.dropFirst() {
            #expect(frame.width == frames[0].width)
            #expect(frame.minX == frames[0].minX)
            #expect(frame.height == frames[0].height)
        }
        // Window coordinates are y-up: each next button is lower.
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            #expect(lower.maxY <= upper.minY, "\(lower) is not under \(upper)")
            // Backing-pixel rounding may move a frame half a point.
            #expect(abs(upper.minY - lower.maxY - Metrics.space2) <= 0.5)
        }
    }

    /// One clear primary (the accent fill, Return), the Always Allow choices as secondary grays with no key, and Deny
    /// as quiet red text with Escape: never a filled red block.
    @Test func oneFilledPrimaryAndAQuietDeny() throws {
        let (view, window) = Self.laidOut()
        defer { window.close() }
        let once = try #require(view.buttonView("once"))
        let deny = try #require(view.buttonView("deny"))
        #expect(once.keyHint == .return)
        #expect(deny.keyHint == .escape)
        #expect(deny.isQuiet)
        #expect(!once.isQuiet)
        #expect(deny.look.fill.alpha == 0, "Deny draws no fill at rest")
        #expect(once.look.fill.alpha == 1, "Allow Once is the one solid fill")
        for id in ["alwaysView", "alwaysFull"] {
            let button = try #require(view.buttonView(id))
            #expect(button.keyHint == nil)
            #expect(button.look.fill.alpha < 1)
        }
        var pressed: [String] = []
        view.dialog.onPress = { pressed.append($0) }
        #expect(view.dialog.handle(.return, modifiers: []))
        #expect(view.dialog.handle(.escape, modifiers: []))
        #expect(pressed == ["once", "deny"])
    }

    /// The fingerprint: its caption, then the code in monospaced digits, one line per line given, on a well that rounds
    /// as the buttons do.
    @Test func theCodeReadsInMonospacedLinesOnAWell() throws {
        let (view, window) = Self.laidOut()
        defer { window.close() }
        let all = Self.views(under: view)
        let code = try #require(all.compactMap { $0 as? ChromeLabel }.first { $0.identifier?.rawValue == "cmux.dialog.code" })
        #expect(code.stringValue == "78BE 18E0 C08C 9C4D\n7443 D95E 2DB6 8074")
        #expect(code.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(code.isSelectable, "the code can be copied to compare it")
        let well = try #require(all.first { $0 is CmuxDialogCodeWell })
        #expect(well.layer?.cornerRadius == CmuxDialogMetrics.buttonCornerRadius)
        #expect(code.isDescendant(of: well))
        #expect(all.compactMap { $0 as? ChromeLabel }.contains { $0.stringValue == "Device key fingerprint" })
    }

    @Test func aFailedAnswerShowsAboveTheButtons() throws {
        let (view, window) = Self.laidOut()
        defer { window.close() }
        let error = try #require(Self.views(under: view).compactMap { $0 as? ChromeLabel }.first { $0.identifier?.rawValue == "cmux.dialog.error" })
        #expect(error.stringValue == Self.spec.error)
        let once = try #require(view.buttonView("once"))
        #expect(error.convert(error.bounds, to: nil).minY > once.convert(once.bounds, to: nil).maxY)
        let (plain, plainWindow) = Self.laidOut(CmuxDialogSpec(title: "T", buttons: [.ok()], layout: .stacked))
        defer { plainWindow.close() }
        #expect(!Self.views(under: plain).contains { $0.identifier?.rawValue == "cmux.dialog.error" })
    }

    @Test func answeringDisablesEveryButton() throws {
        let (view, window) = Self.laidOut()
        defer { window.close() }
        view.setButtonsEnabled(false)
        for id in ["once", "alwaysView", "alwaysFull", "deny"] { #expect(view.buttonView(id)?.isEnabled == false) }
        view.setButtonsEnabled(true)
        for id in ["once", "alwaysView", "alwaysFull", "deny"] { #expect(view.buttonView(id)?.isEnabled == true) }
    }

    /// SECURITY: a person-only button (a consent's Allow) shows no keycap and no key presses it: only the person's own
    /// click answers it (``CmuxDialogPersonClick``).
    @Test func aPersonOnlyButtonTakesNoKey() {
        let spec = CmuxDialogSpec(title: "Allow?", buttons: [
            CmuxDialogButton(id: "deny", title: "Deny", role: .cancel),
            CmuxDialogButton(id: "allow", title: "Allow", role: .default, key: "a", personOnly: true),
        ])
        let dialog = CmuxDialogPresentation(id: 1, spec: spec, activeLook: nil)
        #expect(dialog.hint(for: spec.buttons[1]) == nil)
        #expect(dialog.hint(for: spec.buttons[0]) == .escape)
        var pressed: [String] = []
        dialog.onPress = { pressed.append($0) }
        #expect(!dialog.handle(.return, modifiers: []))
        #expect(!dialog.handle(.character("a"), modifiers: .command))
        #expect(dialog.handle(.escape, modifiers: []))
        #expect(pressed == ["deny"])
    }

    static func views(under root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + views(under: $0) }
    }
}

/// The window of a prompt over every app (``CmuxFloatingDialogPanel``): the cmux dialog card at the top right of the
/// screen, shown without taking the keyboard or activating cmux; gone at once when answered.
@MainActor
struct CmuxFloatingDialogPanelTests {
    @Test func theCardFloatsTopRightWithoutTakingTheKeyboard() throws {
        let panel = CmuxFloatingDialogPanel(identifier: "test.floating")
        defer { panel.close() }
        var pressed: [String] = []
        let view = panel.show(CmuxDialogStackedLayoutTests.spec) { pressed.append($0) }
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .statusBar)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.isKeyWindow, "showing never takes the keyboard")
        #expect(panel.canBecomeKey, "a click into the card gives it the keyboard")
        #expect(view.surface != nil, "the card draws on the dialog glass")
        let card = try #require(panel.cardFrame)
        #expect(abs(card.width - view.fittingSize.width) < 1 && abs(card.height - view.fittingSize.height) < 1)
        if let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            #expect(abs(area.maxX - card.maxX - CmuxFloatingDialogPanel.screenMargin) < 1)
            #expect(abs(area.maxY - card.maxY - CmuxFloatingDialogPanel.screenMargin) < 1)
        }
        // The card's own key answers reach the host.
        #expect(view.dialog.handle(.escape, modifiers: []))
        #expect(pressed == ["deny"])
        panel.hide()
        #expect(panel.cardFrame == nil)
        #expect(!panel.isVisible)
    }

    @Test func aNewSpecReplacesTheCardInPlace() throws {
        let panel = CmuxFloatingDialogPanel(identifier: "test.floating")
        defer { panel.close() }
        let first = panel.show(CmuxDialogSpec(title: "One", buttons: [.ok()])) { _ in }
        let second = panel.show(CmuxDialogStackedLayoutTests.spec) { _ in }
        #expect(first.superview == nil)
        #expect(panel.dialogView === second)
        let card = try #require(panel.cardFrame)
        #expect(abs(card.height - second.fittingSize.height) < 1)
    }
}

/// A floating dialog never stays up with no content (Lawrence 2026-11-17, a stuck empty glass card): a card with no
/// title and no lines is not shown, and showing one hides the panel.
@MainActor
struct CmuxFloatingDialogNeverEmptyTests {
    @Test func anEmptyCardIsNeverShown() {
        let panel = CmuxFloatingDialogPanel(identifier: "test.empty")
        defer { panel.close() }
        panel.show(CmuxDialogSpec(title: "One", buttons: [.ok()])) { _ in }
        #expect(panel.isVisible)
        panel.show(CmuxDialogSpec(title: "", buttons: [.ok()])) { _ in }
        #expect(!panel.isVisible, "an empty card hides the panel")
        #expect(panel.cardFrame == nil)
    }

    /// A content view that holds no card is never shown either.
    @Test func aHostWithNoCardIsNeverShown() {
        let panel = CmuxFloatingDialogPanel(identifier: "test.empty")
        defer { panel.close() }
        panel.present(NSView())
        #expect(!panel.isVisible)
    }
}
