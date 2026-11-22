import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Toasts v2 (Settings > Advanced > Experiments, `experiments.toastsV2`; the coordinator's taste build list, 2026-11-19:
/// "One toast starts as a spinner ('Running tests…') and turns into success or error in place without
/// stacking"): a working toast leads with a spinner, its result takes its slot, and the switch draws every
/// toast in the v2 look (a mark for the tone, Undo as an ink-filled button). Off, nothing changes.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct CmuxToastV2Tests {
    private static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    }

    private static func close(_ window: NSWindow) {
        let panel = WindowOverlayHost.existingHost(for: window)?.panel
        window.closeAfterTest()
        panel?.close()
    }

    private static func center() -> CmuxToastCenter {
        CmuxToastCenter(clock: ContinuousClock(), host: CmuxToastOverlayHost(reduceTransparency: .alwaysOpaque))
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

    /// A working toast leads with the spinner in every style, and never with a tone icon.
    @Test(arguments: CmuxToastStyle.allCases)
    func aWorkingToastSpinsInEveryStyle(style: CmuxToastStyle) {
        let view = CmuxToastView(toast: CmuxToast(id: "tests", message: "Running tests…", duration: CmuxToast.untilClosed, tone: .working),
                                 reduceTransparency: .alwaysOpaque, style: style)
        view.layoutSubtreeIfNeeded()
        #expect(view.spinnerView != nil)
        #expect(view.iconView == nil)
    }

    /// The result of a working toast takes its slot, even after a newer toast came: one card, never a second.
    @Test func theResultTakesTheWorkingToastsSlot() {
        let center = Self.center()
        let window = Self.window()
        defer { Self.close(window) }
        center.show(CmuxToast(id: "tests", message: "Running tests…", duration: CmuxToast.untilClosed, tone: .working), in: window)
        center.show(CmuxToast(id: "closed", message: "Closed “Build logs”", action: .undo()), in: window)
        center.show(CmuxToast(id: "tests", message: "Tests passed", tone: .success), in: window)
        let shown = center.toasts(in: window)
        #expect(shown.map(\.id) == ["tests", "closed"], "the result rests where the spinner was")
        #expect(shown.first?.message == "Tests passed")
        #expect(Self.toastViews(in: window).count == 2)
    }

    /// Any other toast replaced under its id still rests newest, as before.
    @Test func aPlainToastReplacedRestsNewest() {
        var stack = CmuxToastStack()
        _ = stack.push(serial: 1, id: "a", undo: false)
        _ = stack.push(serial: 2, id: "b", undo: false)
        #expect(stack.push(serial: 3, id: "a", undo: false) == [1])
        #expect(stack.serials == [2, 3])
        #expect(stack.push(serial: 4, id: "b", undo: false, keepsSlot: true) == [2])
        #expect(stack.serials == [4, 3])
    }

    /// The switch draws every toast in the v2 look, those showing at once; off, the pick again.
    @Test func theSwitchRestylesEveryToast() throws {
        let center = Self.center()
        let window = Self.window()
        defer { Self.close(window) }
        center.show(CmuxToast(id: "closed", message: "Closed “Build logs”", action: .undo()), in: window)
        #expect(center.style == .standard)
        center.v2 = true
        #expect(center.style == .v2)
        let view = try #require(Self.toastViews(in: window).first)
        #expect(view.style == .v2)
        center.v2 = false
        #expect(try #require(Self.toastViews(in: window).first).style == .standard)
    }

    /// The v2 look: plain news has no mark, a result has its tone's, and Undo is an ink-filled button.
    @Test func theV2LookMarksTheToneAndInksTheAction() {
        let undo = CmuxToastView(toast: CmuxToast(id: "closed", message: "Closed “Build logs”", action: .undo()),
                                 reduceTransparency: .alwaysOpaque, style: .v2)
        #expect(undo.iconView == nil, "a one-line Undo toast carries no mark")
        #expect(undo.actionButton?.style == .ink)
        let failed = CmuxToastView(toast: CmuxToast(id: "tests", message: "2 tests failed", tone: .error),
                                   reduceTransparency: .alwaysOpaque, style: .v2)
        #expect(failed.iconSymbol == CmuxToastTone.error.symbolName)
        #expect(failed.iconView != nil)
    }
}
