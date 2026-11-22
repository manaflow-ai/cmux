#if DEBUG
import AppKit

/// DEBUG ONLY: playground variant 4: Before and After side by side, each in its own scroll view whose zoom and
/// scroll follow the other's (pinch or scroll either one; both show the same spot), with a Light | Dark switch.
@MainActor
final class HomeCompareSyncedZoomVariant: NSView {
    private let fixture: HomeCompareFixture
    /// One side of the pair: its scroll view, the picture in it and its name above it.
    @MainActor private struct Side {
        let pane = HomeCompareSyncedScroll(frame: .zero)
        let image = TopImageView(frame: .zero)
        let label = NSTextField(labelWithString: "")
    }
    /// A picture that starts at the scroll view's top (an unflipped document view smaller than its clip view
    /// sits at the bottom, under an empty band).
    private final class TopImageView: NSImageView {
        override var isFlipped: Bool { true }
    }
    private let sides = [Side(), Side()]
    private let rows = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)

    init(fixture: HomeCompareFixture, row: Int) {
        self.fixture = fixture
        super.init(frame: .zero)
        rows.segmentCount = fixture.rowTitles.count
        for (i, title) in fixture.rowTitles.enumerated() { rows.setLabel(title, forSegment: i) }
        rows.segmentStyle = .capsule
        rows.target = self
        rows.action = #selector(changed)
        rows.selectedSegment = row
        addSubview(rows)
        for (i, side) in sides.enumerated() {
            let pane = side.pane
            pane.allowsMagnification = true
            pane.minMagnification = 0.25
            pane.maxMagnification = 6
            pane.hasHorizontalScroller = true
            pane.hasVerticalScroller = true
            pane.autohidesScrollers = true
            pane.drawsBackground = false
            side.image.imageScaling = .scaleAxesIndependently
            pane.documentView = side.image
            pane.partner = sides[checked: 1 - i]?.pane
            side.label.stringValue = fixture.columnTitles[checked: i] ?? ""
            side.label.font = HomeFonts.system(ofSize: 12, weight: .semibold)
            side.label.textColor = .secondaryLabelColor
            addSubview(pane)
            addSubview(side.label)
        }
        changed()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    @objc private func changed() {
        for (i, side) in sides.enumerated() {
            guard let picture = fixture.picture(row: rows.selectedSegment, column: i) else { continue }
            let size = NSSize(width: picture.width / 2, height: picture.height / 2)
            side.image.image = NSImage(cgImage: picture, size: size)
            side.image.frame = CGRect(origin: .zero, size: size)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let r = rows.fittingSize
        rows.frame = CGRect(x: (bounds.midX - r.width / 2).rounded(), y: 12, width: r.width, height: r.height)
        let top = rows.frame.maxY + 34, gap: CGFloat = 12
        let w = ((bounds.width - 32 - gap) / 2).rounded(.down), h = bounds.height - top - 16
        for (i, side) in sides.enumerated() {
            let x = 16 + CGFloat(i) * (w + gap)
            side.label.frame = CGRect(x: x, y: top - 22, width: w, height: 16)
            side.pane.frame = CGRect(x: x, y: top, width: w, height: h)
            let doc = side.image.frame.size
            if doc.width > 0 { side.pane.magnification = min(w / doc.width, h / doc.height) }
        }
    }
}

#endif
