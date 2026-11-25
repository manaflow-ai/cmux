import AppKit
import CmuxNextDesignTokens
@testable import CmuxNextDesign
import Testing

/// Containers that hold buttons are concentric with them (Lawrence 2026-11-15, on the "Option or Shift + drag
/// selects text | Don't Show Again | ×" hint: "all dialogs needs concentric padding with buttons inside"): the
/// container's corner is the button's corner plus the padding, the padding is the same on the top, the bottom
/// and the near side, and text that leads the container starts clear of the corner's curve. These measure the
/// laid-out surfaces (``ConcentricContainer/violations(child:childRadius:in:outerRadius:padding:tolerance:)``).
@MainActor @Suite(.serialized) struct ConcentricButtonContainerTests {
    /// The hint toast of the report: a message, Don't Show Again and close.
    private static let hint = CmuxToast(id: "terminal.selectionHint", message: "Option or Shift + drag selects text")
    /// A toast with an action, Don't Show Again and close.
    private static let action = CmuxToast(id: "concentric.action", message: "Closed “zsh”", action: CmuxToast.Action(title: "Reopen"))

    /// The padding a toast in `style` means between its edge and its buttons: its vertical padding.
    private static func toastPadding(_ style: CmuxToastStyle) -> CGFloat {
        let vertical = CmuxToastTuning().padding
        return Metrics.scale(style.look.compact ? (vertical * 2 / 3).rounded() : vertical)
    }

    private static func laidOut(_ toast: CmuxToast, _ style: CmuxToastStyle) -> CmuxToastView {
        let view = CmuxToastView(toast: toast, style: style)
        view.frame.size = view.fittingSize
        view.layoutSubtreeIfNeeded()
        view.layout()
        return view
    }

    private static func buttons(of view: CmuxToastView) -> [CmuxToastButton] {
        [view.secondaryButton, view.actionButton, view.neverShowButton, view.closeButton].compactMap { $0 }
    }

    @Test(arguments: CmuxToastStyle.allCases)
    func everyToastButtonIsConcentricWithTheToast(style: CmuxToastStyle) throws {
        for toast in [Self.hint, Self.action] {
            let view = Self.laidOut(toast, style)
            let surface = try #require(view.surface)
            let padding = Self.toastPadding(style)
            for button in Self.buttons(of: view) {
                let frame = button.convert(button.bounds, to: view)
                let radius = try #require(button.layer).cornerRadius
                let broken = ConcentricContainer.violations(child: frame, childRadius: radius, in: view.bounds,
                                                            outerRadius: surface.cornerRadius, padding: padding)
                #expect(broken.isEmpty, "\(style) \(toast.id): \(button.accessibilityLabel() ?? "?") at \(frame) in \(view.bounds) r\(surface.cornerRadius): \(broken)")
            }
        }
    }

    /// Every button in one toast shares one hover shape: the toast's corner less its padding.
    @Test(arguments: CmuxToastStyle.allCases)
    func everyToastButtonHoversInOneConcentricShape(style: CmuxToastStyle) throws {
        let view = Self.laidOut(Self.action, style)
        let surface = try #require(view.surface)
        let padding = Self.toastPadding(style)
        for button in Self.buttons(of: view) {
            let expected = max(0, min(surface.cornerRadius - padding, min(button.bounds.width, button.bounds.height) / 2))
            let radius = try #require(button.layer).cornerRadius
            #expect(abs(radius - expected) <= 0.5,
                    "\(style): \(button.accessibilityLabel() ?? "?") hovers at r\(radius), the toast is r\(surface.cornerRadius) with \(padding) pt padding")
        }
    }

    /// The message starts clear of the corner: as far in as the toast's corner (the text of a button sits inside
    /// its own concentric shape the same way), past the accent bar when there is one.
    @Test(arguments: CmuxToastStyle.allCases.filter { !$0.look.showsIcon })
    func theMessageStartsClearOfTheCorner(style: CmuxToastStyle) throws {
        let view = Self.laidOut(Self.hint, style)
        let surface = try #require(view.surface)
        let message = try #require(view.messageLabel)
        // The text starts at the label's alignment rect (a label's frame reaches 2 pt past its glyphs).
        let leading = message.convert(message.alignmentRect(forFrame: message.bounds), to: view).minX - (style.look.accentBar ? CmuxToastView.accentBarWidth : 0)
        #expect(abs(leading - surface.cornerRadius) <= 1,
                "\(style): the message starts \(leading) pt in, the toast's corner is \(surface.cornerRadius) pt")
    }

    /// An icon that leads the toast sits as far from the leading edge as from the top and bottom.
    @Test func aLeadingIconHasEqualPadding() throws {
        let view = Self.laidOut(Self.hint, .iconCard)
        let icon = try #require(view.iconView)
        // The symbol's alignment rect, where layout puts it (a symbol image view's frame reaches past its glyph).
        let frame = icon.convert(icon.alignmentRect(forFrame: icon.bounds), to: view)
        let top = view.bounds.height - frame.maxY, bottom = frame.minY
        #expect(abs(top - bottom) <= 1 && abs(frame.minX - top) <= 1,
                "the icon \(frame) in \(view.bounds) is \(frame.minX) pt from the side, \(top) from the top, \(bottom) from the bottom")
    }

    /// The dialog card rounds from its buttons: its corner is the button corner plus the card's padding, and the
    /// buttons on its bottom row sit that padding from the bottom and the sides.
    @Test func theDialogCardIsConcentricWithItsButtons() throws {
        let spec = CmuxDialogSpec(title: "Close this window?", lines: ["Its terminals and agents keep running."],
                                  buttons: [CmuxDialogButton(id: "cancel", title: "Cancel", role: .cancel),
                                            CmuxDialogButton(id: "close", title: "Close", role: .default)])
        let view = CmuxDialogView(dialog: CmuxDialogPresentation(id: 1, spec: spec, activeLook: nil))
        view.frame.size = view.fittingSize
        view.layoutSubtreeIfNeeded()
        let glass = try #require(view.surface).glass
        glass.layoutSubtreeIfNeeded()
        #expect(!view.buttonViews.isEmpty)
        for button in view.buttonViews {
            let frame = button.convert(button.bounds, to: view)
            let radius = try #require(button.layer).cornerRadius
            let broken = ConcentricContainer.violations(child: frame, childRadius: radius, in: view.bounds,
                                                        outerRadius: glass.cornerRadius, padding: CmuxDialogMetrics.cardPadding)
            #expect(broken.isEmpty, "\(button.button.id) at \(frame) in \(view.bounds) r\(glass.cornerRadius): \(broken)")
        }
    }
}
