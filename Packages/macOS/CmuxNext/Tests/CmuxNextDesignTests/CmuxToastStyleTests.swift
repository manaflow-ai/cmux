import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The toast style the person picks in the Toast Playground (Lawrence 2026-11-13: "we need to improve all
/// our toasts/prompts, make a swift playground for me to pick my favorite"): the pick persists, and every
/// toast and prompt the app draws takes it at once, the ones already showing included.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct CmuxToastStyleTests {
    /// Every kind of toast the app shows: a hint, a notice with Don't Show Again, an Undo, a Details, an
    /// error and a prompt with two actions.
    static let everyKind: [CmuxToast] = [
        CmuxToast(id: "hint", message: "Option or Shift + drag selects text"),
        CmuxToast(id: "notice", message: "Saved the layout", detail: "3 panes, 2 tabs"),
        CmuxToast(id: "undo", message: "Closed “New Tab”", action: .undo()),
        CmuxToast(id: "details", message: "1 agent could not be stopped", detail: "a2: refused", action: .details("Details")),
        CmuxToast(id: CmuxToast.refusalID, message: "No room for another split", tone: .error),
        CmuxToast(id: "update", message: "A server update is ready", action: CmuxToast.Action(title: "Restart"),
                  secondaryAction: CmuxToast.Action(title: "Later"), duration: CmuxToast.untilClosed),
    ]

    private static func defaults() -> UserDefaults {
        let name = "cmux.toastStyleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    }

    private static func close(_ window: NSWindow) {
        let panel = WindowOverlayHost.existingHost(for: window)?.panel
        window.closeAfterTest()
        panel?.close()
    }

    /// The toast views shown over `window`: they live in its overlay panel.
    private static func toastViews(in window: NSWindow) -> [CmuxToastView] {
        var found: [CmuxToastView] = []
        var pending: [NSView] = WindowOverlayHost.host(for: window).panel.contentView.map { [$0] } ?? []
        while let view = pending.popLast() {
            if let toast = view as? CmuxToastView { found.append(toast) } else { pending.append(contentsOf: view.subviews) }
        }
        return found
    }

    // MARK: The pick

    /// Nothing picked: today's look. A pick persists, so the next launch's store reads it back.
    @Test func thePickPersistsAcrossLaunches() {
        let defaults = Self.defaults()
        #expect(CmuxToastStyleStore(defaults: defaults).style == .standard, "the default is today's look until the person picks")
        CmuxToastStyleStore(defaults: defaults).pick(.capsule)
        #expect(CmuxToastStyleStore(defaults: defaults).style == .capsule)
        CmuxToastStyleStore(defaults: defaults).pick(.standard)
        #expect(CmuxToastStyleStore(defaults: defaults).style == .standard)
    }

    /// A style a later build no longer has falls back to today's look, never a crash or an empty toast.
    @Test func anUnknownStoredStyleIsTheDefault() {
        let defaults = Self.defaults()
        defaults.set("removed-style", forKey: CmuxToastStyleStore.key)
        #expect(CmuxToastStyleStore(defaults: defaults).style == .standard)
    }

    /// The playground offers at least eight clearly different designs, each with its own title and
    /// one-line description.
    @Test func thePlaygroundOffersEightOrMoreDesigns() {
        #expect(CmuxToastStyle.allCases.count >= 8)
        #expect(Set(CmuxToastStyle.allCases.map(\.look)).count == CmuxToastStyle.allCases.count, "two styles draw the same")
        #expect(Set(CmuxToastStyle.allCases.map(\.title)).count == CmuxToastStyle.allCases.count)
        for style in CmuxToastStyle.allCases { #expect(!style.summary.isEmpty) }
    }

    // MARK: The playground

    /// The playground shows every style, or one alone (Debug Settings > Toasts > Playground shows), each with
    /// every kind in a light and a dark sheet; its choices follow the styles.
    @Test func thePlaygroundShowsEveryStyleOrOne() {
        #expect(CmuxToastPlaygroundFocus.allCases.count == CmuxToastStyle.allCases.count + 1)
        #expect(CmuxToastPlaygroundFocus(rawValue: "removed-style") == nil)
        let center = CmuxToastCenter(clock: ContinuousClock(), styles: CmuxToastStyleStore(defaults: Self.defaults()))
        let themes = CmuxToastPlaygroundThemes(colors: [:])
        let every = CmuxToastPlaygroundView(center: center, themes: themes) { _ in }
        #expect(every.rows.map(\.style) == CmuxToastStyle.allCases)
        for row in every.rows {
            #expect(row.sheets.map(\.isDark) == [false, true])
            for sheet in row.sheets { #expect(sheet.toasts.map(\.toast.id) == CmuxToastPlaygroundSamples.kinds.map(\.id)) }
        }
        let one = CmuxToastPlaygroundView(center: center, themes: themes, focus: .only(.progressRing)) { _ in }
        #expect(one.rows.map(\.style) == [.progressRing])
    }

    // MARK: Every kind takes it

    /// Picking a style restyles every toast already showing, of every kind, in every window, and the next
    /// toast shows in it too.
    @Test(arguments: CmuxToastStyle.allCases)
    func thePickAppliesToEveryKindAtOnce(style: CmuxToastStyle) throws {
        let center = CmuxToastCenter(clock: ContinuousClock(), host: CmuxToastOverlayHost(reduceTransparency: .alwaysOpaque),
                                     styles: CmuxToastStyleStore(defaults: Self.defaults()))
        let first = Self.window(), second = Self.window()
        defer { Self.close(first); Self.close(second) }
        for toast in Self.everyKind.prefix(3) { center.show(toast, in: first) }
        for toast in Self.everyKind.suffix(3) { center.show(toast, in: second) }
        center.pick(style)
        let shown = Self.toastViews(in: first) + Self.toastViews(in: second)
        #expect(shown.count == Self.everyKind.count)
        for view in shown { #expect(view.style == style, "\(view.toast.id) kept \(view.style)") }
        center.show(CmuxToast(id: "later", message: "Copied"), in: first)
        let later = try #require(Self.toastViews(in: first).first { $0.toast.id == "later" })
        #expect(later.style == style)
    }

    /// Each style draws what it promises for every kind: the two actions of a prompt, an icon where the
    /// style has one, a filled primary button, a capsule's round ends, the countdown ring.
    @Test(arguments: CmuxToastStyle.allCases)
    func everyStyleDrawsEveryKind(style: CmuxToastStyle) {
        for toast in Self.everyKind {
            let view = CmuxToastView(toast: toast, reduceTransparency: .alwaysOpaque, style: style)
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width > 80 && view.fittingSize.height >= 20, "\(style) \(toast.id) drew nothing")
            #expect((view.actionButton != nil) == (toast.action != nil))
            #expect((view.secondaryButton != nil) == (toast.secondaryAction != nil))
            #expect((view.iconView != nil) == style.look.showsIcon)
            #expect((view.countdownRing != nil) == (style.look.showsCountdown && toast.duration != CmuxToast.untilClosed))
            if toast.action != nil { #expect(view.actionButton?.isFilled == style.look.fillsAction) }
        }
    }

    /// A capsule's corners are half its height; the others keep the toast role's radius.
    @Test func theCapsuleHasRoundEnds() {
        let capsule = CmuxToastView(toast: Self.everyKind[0], reduceTransparency: .alwaysOpaque, style: .capsule)
        capsule.setFrameSize(capsule.fittingSize)
        capsule.layoutSubtreeIfNeeded()
        #expect(abs(capsule.cornerRadius - capsule.bounds.height / 2) < 0.5)
        let standard = CmuxToastView(toast: Self.everyKind[0], reduceTransparency: .alwaysOpaque, style: .standard)
        #expect(standard.cornerRadius == SurfaceRole.toast.cornerRadius)
    }

    /// The error tone shows as an error wherever a style marks the tone (the icon), and a refusal is an
    /// error without saying so.
    @Test func aRefusalIsAnError() {
        #expect(CmuxToast(id: CmuxToast.refusalID, message: "No room").tone == .error)
        #expect(CmuxToast(id: "saved", message: "Saved").tone == .neutral)
        let view = CmuxToastView(toast: CmuxToast(id: CmuxToast.refusalID, message: "No room"), reduceTransparency: .alwaysOpaque, style: .iconCard)
        #expect(view.iconSymbol == CmuxToastTone.error.symbolName)
    }

    // MARK: Two actions

    /// A prompt's second action runs its own handler and ends the toast; the first runs only its own.
    @Test func thePromptsSecondActionRunsAndEndsIt() {
        let center = CmuxToastCenter(clock: ContinuousClock(), styles: CmuxToastStyleStore(defaults: Self.defaults()))
        let window = Self.window()
        defer { Self.close(window) }
        let handle = center.show(Self.everyKind[5], in: window)
        var ran: [String] = []
        handle.onAction = { ran.append("primary") }
        handle.onSecondaryAction = { ran.append("secondary") }
        var reason: CmuxToastDismissReason?
        handle.onDismiss = { reason = $0 }
        center.personRanSecondaryAction(serial: handle.serial)
        #expect(ran == ["secondary"])
        #expect(reason == .action)
        #expect(center.toasts(in: window).isEmpty)
    }

    /// A prompt asks for an answer: it never offers Don't Show Again.
    @Test func aPromptNeverOffersDontShowAgain() {
        #expect(!Self.everyKind[5].offersNeverShow)
        #expect(!CmuxToast(id: "p", message: "Restart?", action: .init(title: "Restart"), secondaryAction: .init(title: "Later")).offersNeverShow)
    }

    // MARK: Fire it

    /// The playground's Fire it shows one style as a real toast, whatever the pick is: a toast that names
    /// its style keeps it, and the bottom-trailing style rests at the window's trailing edge.
    @Test func aToastThatNamesItsStyleKeepsIt() throws {
        let center = CmuxToastCenter(clock: ContinuousClock(), host: CmuxToastOverlayHost(reduceTransparency: .alwaysOpaque),
                                     styles: CmuxToastStyleStore(defaults: Self.defaults()))
        let window = Self.window()
        defer { Self.close(window) }
        var toast = Self.everyKind[0]
        toast.style = .trailing
        center.show(toast, in: window)
        let view = try #require(Self.toastViews(in: window).first)
        #expect(view.style == .trailing)
        let frame = view.convert(view.bounds, to: nil)
        let bounds = try #require(window.contentView?.bounds)
        #expect(frame.maxX > bounds.maxX - 40, "a trailing toast rests at the trailing edge, not centered")
        #expect(frame.minX > bounds.midX)
        center.pick(.compact)
        #expect(Self.toastViews(in: window).first?.style == .trailing, "the pick does not restyle a toast that names its style")
    }
}
