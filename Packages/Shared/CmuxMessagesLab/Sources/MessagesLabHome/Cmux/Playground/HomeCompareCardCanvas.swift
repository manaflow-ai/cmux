#if DEBUG
import AppKit

/// DEBUG ONLY: draws a table card with the real row code (``HomeTableGrid``) and reports a click on a loaded
/// picture with its frame and thumbnail (``HomeCompareCardVariant``).
@MainActor
final class HomeCompareCardCanvas: NSView {
    private let table: HomeTable?
    private let style: HomeTableGrid.Style
    var onPicture: (String, CGRect, CGImage) -> Void = { _, _, _ in }

    init(table: HomeTable?, style: HomeTableGrid.Style) {
        self.table = table
        self.style = style
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func height(for width: CGFloat) -> CGFloat {
        table.map { HomeTableGrid($0, available: width, style: style).height } ?? 0
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let table, let ctx = NSGraphicsContext.current?.cgContext else { return }
        HomeTableGrid(table, available: bounds.width, style: style).draw(ctx, at: .zero)
    }

    override func mouseDown(with event: NSEvent) {
        guard let table else { return }
        let p = convert(event.locationInWindow, from: nil)
        let grid = HomeTableGrid(table, available: bounds.width, style: style)
        guard let hit = grid.pictureRects(at: .zero).first(where: { !$0.loading && $0.rect.contains(p) }),
              let image = grid.slots.lazy.flatMap({ $0 }).flatMap({ $0 }).first(where: { $0.source == hit.source })?.image else { return }
        onPicture(hit.source, hit.rect, image)
    }
}
#endif
