#if DEBUG
import AppKit

/// DEBUG ONLY: playground variants 6 and 7: the Home table card itself, drawn by the real row code
/// (``HomeTableGrid``) at the stage's width: large pairs (``HomeCompareLayout``, what Home draws now) or the
/// plain grid (one thumbnail per cell, the header rule clear of the empty corner). A click on a picture opens
/// the real picture viewer over the stage, growing out of the thumbnail.
@MainActor
final class HomeCompareCardVariant: NSView {
    private let table: HomeTable?
    private let scroll = NSScrollView(frame: .zero)
    private let canvas: HomeCompareCardCanvas

    init(table: HomeTable?, style: HomeTableGrid.Style) {
        self.table = table
        canvas = HomeCompareCardCanvas(table: table, style: style)
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = canvas
        canvas.onPicture = { [weak self] source, rect, image in self?.open(source, from: rect, image: image) }
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func open(_ source: String, from rect: CGRect, image: CGImage) {
        guard let table, let gallery = HomePictureGallery(table: table, opening: source) else { return }
        let viewer = HomePictureViewer(frame: bounds, gallery: gallery, load: { item in
            HomeMarkdownPolicy.images.markdownImage(source: URL(fileURLWithPath: item.url.path).absoluteString, alt: "")
        })
        addSubview(viewer, positioned: .above, relativeTo: nil)
        window?.makeFirstResponder(viewer)
        viewer.present(from: convert(rect, from: canvas), thumbnail: image)
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 16, dy: 12)
        let width = scroll.contentSize.width
        canvas.frame = CGRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, canvas.height(for: width)))
    }
}
#endif
