import AppKit
@testable import CmuxNextDesign
import Testing

/// QUIT P0 review (#29984): a dialog whose buttons do not fit on one line of the 380 pt card (the quit choice: Keep
/// Sessions Running, End Sessions, Keep Layout, End Everything, Cancel) stacks them, the default on top, each the
/// card's width, as NSAlert does; no button is clipped or pushed off the card. Buttons that fit stay on one line.
@MainActor
struct CmuxDialogButtonFitTests {
    private static let quitSpec = CmuxDialogSpec(title: "Quit cmux?", buttons: [
        CmuxDialogButton(id: "end-keep-layout", title: "End Sessions, Keep Layout", role: .destructive),
        CmuxDialogButton(id: "end-everything", title: "End Everything", role: .destructive),
        CmuxDialogButton(id: "cancel", title: "Cancel", role: .cancel),
        CmuxDialogButton(id: "keep", title: "Keep Sessions Running", role: .default),
    ])

    @Test func buttonsThatDoNotFitStackInsideTheCardWithTheDefaultOnTop() {
        let view = CmuxDialogView(spec: Self.quitSpec)
        view.layoutSubtreeIfNeeded()
        let card = view.bounds
        #expect(card.width > 0 && card.height > 0)
        let frames = view.buttonViews.map { ($0.button.id, $0.convert($0.bounds, to: view)) }
        for (id, frame) in frames {
            #expect(card.insetBy(dx: -0.5, dy: -0.5).contains(frame), "button \(id) at \(frame) is outside the card \(card)")
            #expect(frame.width >= Self.fitting(view, id) - 0.5, "button \(id) is narrower than its title and key hint")
        }
        let top = frames.max { $0.1.midY < $1.1.midY }   // AppKit: y grows upward
        #expect(top?.0 == "keep", "the default is not the top button: \(frames.map(\.0))")
    }

    @Test func tabWalksTheStackedButtonsTopToBottom() {
        let view = CmuxDialogView(spec: Self.quitSpec)
        view.layoutSubtreeIfNeeded()
        let order = view.focusables.compactMap { ($0 as? CmuxDialogButtonView)?.button.id }
        #expect(order == ["keep", "cancel", "end-everything", "end-keep-layout"], "Tab order: \(order)")
    }

    @Test func buttonsThatFitStayOnOneLine() {
        let view = CmuxDialogView(spec: CmuxDialogSpec(title: "Close tab?", buttons: [
            CmuxDialogButton(id: "cancel", title: "Cancel", role: .cancel),
            CmuxDialogButton(id: "close", title: "Close", role: .default),
        ]))
        view.layoutSubtreeIfNeeded()
        let ys = Set(view.buttonViews.map { $0.convert($0.bounds, to: view).midY.rounded() })
        #expect(ys.count == 1, "two short buttons were stacked")
    }

    private static func fitting(_ view: CmuxDialogView, _ id: String) -> CGFloat {
        view.buttonViews.first { $0.button.id == id }?.intrinsicContentSize.width ?? 0
    }
}
