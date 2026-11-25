#if DEBUG
import AppKit

/// DEBUG ONLY: playground variant 5, filmstrip: one picture large on the stage and every picture of the table
/// as a strip of named thumbnails under it; a click on a thumbnail (or Left and Right) puts it on the stage.
@MainActor
final class HomeCompareFilmstripVariant: NSView {
    private let fixture: HomeCompareFixture
    private let stage = NSImageView(frame: .zero)
    private var thumbs: [NSButton] = []
    private var cells: [(row: Int, column: Int)] = []
    private var selected = 0

    init(fixture: HomeCompareFixture, row: Int) {
        self.fixture = fixture
        super.init(frame: .zero)
        stage.imageScaling = .scaleProportionallyUpOrDown
        stage.wantsLayer = true
        addSubview(stage)
        for (r, rowTitle) in fixture.rowTitles.enumerated() {
            for (c, columnTitle) in fixture.columnTitles.enumerated() {
                guard let picture = fixture.picture(row: r, column: c) else { continue }
                let b = NSButton(title: "\(rowTitle) · \(columnTitle)", target: self, action: #selector(picked(_:)))
                b.image = NSImage(cgImage: picture, size: NSSize(width: 120, height: 75))
                b.imagePosition = .imageAbove
                b.isBordered = false
                b.tag = cells.count
                b.wantsLayer = true
                b.layer?.cornerRadius = 8
                cells.append((r, c))
                thumbs.append(b)
                addSubview(b)
            }
        }
        select(row * fixture.columnTitles.count)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func select(_ i: Int) {
        guard let cell = cells[checked: i] else { return }
        selected = i
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.16
            stage.layer?.add(fade, forKey: "pick")
        }
        stage.image = fixture.picture(row: cell.row, column: cell.column).map { NSImage(cgImage: $0, size: NSSize(width: $0.width / 2, height: $0.height / 2)) }
        for (j, b) in thumbs.enumerated() {
            b.layer?.backgroundColor = j == i ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
        }
    }

    @objc private func picked(_ sender: NSButton) { select(sender.tag) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: select(selected - 1)
        case 124: select(selected + 1)
        default: super.keyDown(with: event)
        }
    }

    override func layout() {
        super.layout()
        let stripHeight: CGFloat = 110, w: CGFloat = 136, gap: CGFloat = 10
        let total = CGFloat(thumbs.count) * w + CGFloat(max(0, thumbs.count - 1)) * gap
        var x = (bounds.midX - total / 2).rounded()
        for b in thumbs {
            b.frame = CGRect(x: x, y: bounds.height - stripHeight, width: w, height: stripHeight - 10)
            x += w + gap
        }
        stage.frame = CGRect(x: 16, y: 12, width: bounds.width - 32, height: bounds.height - stripHeight - 24)
    }
}
#endif
