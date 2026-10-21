import AppKit

extension MessagesWindowView {
    /// The host status line's text (ask 9, the Chief's "working on" line above the typing dots) in
    /// this view's coordinates, a little outset to take a click; nil when it is not on screen.
    func statusLineFrame() -> CGRect? {
        guard !threadOpen else { return nil }
        for case let cell as RowCell in collection.visibleCells where !cell.isHidden {
            guard let spec = cell.spec, case let .notice(text) = spec.kind else { continue }
            let width = min(HomeNoticeRows.width(text), max(spec.metrics.receiptRight - RowDraw.noticeLeft, 0))
            let rect = CGRect(x: RowDraw.noticeLeft, y: RowDraw.margin, width: width, height: spec.height)
            return cell.convert(rect, to: self).insetBy(dx: -4, dy: -3)
        }
        return nil
    }
}
