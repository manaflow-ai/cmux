#if DEBUG
import Foundation

/// DEBUG ONLY: captures of a picture's hover save button (``HomeMediaSaveHover``) with no real pointer.
extension MessagesLabHomeView {
    /// Shows the save button of the `index`th picture or video on screen (top to bottom), as a pointer over its middle
    /// does. False when there is none.
    public func debugHoverMedia(_ index: Int) -> Bool {
        guard let demo = controller.demo else { return false }
        var found: [CGRect] = []
        for case let cell as RowCell in demo.collection.visibleCells {
            guard let spec = cell.spec, case let .part(row) = spec.kind, case let .attachment(a) = row.part,
                  a.kind == "image" || a.kind == "video" else { continue }
            found.append(cell.convert(RowDraw.bodyRect(spec), to: demo))
        }
        found.sort { $0.minY < $1.minY }
        guard let body = found[checked: index] else { return false }
        controller.pointerMovedForSaveHover(CGPoint(x: body.midX, y: body.midY))
        return true
    }
}
#endif
