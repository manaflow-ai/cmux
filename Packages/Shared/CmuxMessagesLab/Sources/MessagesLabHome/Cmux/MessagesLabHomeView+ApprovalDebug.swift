#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

extension MessagesLabHomeView {
    /// Read-only approval state and button boxes, in window points (bottom-left origin).
    /// Capture automation must use real pointer input; there is no decision entrypoint here.
    public func debugApprovalCards() -> [(id: String, text: String, pending: Bool, busy: Bool, ended: Bool, allow: CGRect, deny: CGRect)] {
        guard let demo = controller.demo, controller.host.window != nil, let hostLayer = controller.host.layer else { return [] }
        return demo.collection.visibleCells.compactMap { cell in
            guard let cell = cell as? RowCell, !cell.isHidden, let spec = cell.spec,
                  case .part(let row) = spec.kind, case .custom(let custom) = row.part,
                  let card = HomeApprovalRowProvider.payload(custom) else { return nil }
            let body = RowDraw.bodyRect(spec)
            let layout = HomeApprovalRowProvider.layout(card, width: body.width)
            func inWindow(_ rect: CGRect) -> CGRect {
                let content = cell.contentView.layer
                let box = rect.offsetBy(dx: body.minX, dy: body.minY)
                return controller.host.convert(content.convert(box, to: hostLayer), to: nil)
            }
            return (card.question.id, HomeApprovalRowProvider.text(card), card.question.isPending,
                    card.local.busy, card.local.ended, inWindow(layout.allow), inWindow(layout.deny))
        }
    }
}
#endif
