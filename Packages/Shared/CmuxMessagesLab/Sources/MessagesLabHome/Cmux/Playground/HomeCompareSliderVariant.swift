#if DEBUG
import AppKit

/// DEBUG ONLY: playground variant 1, the default: one pair as large as the stage lets it, Before left of a
/// slider and After right of it (``HomePictureCompare``), with a Light | Dark switch above it. Drag anywhere
/// on the pair to move the divider.
@MainActor
final class HomeCompareSliderVariant: NSView {
    private let fixture: HomeCompareFixture
    private let compare = HomePictureCompare(frame: .zero)
    private let rows = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)

    init(fixture: HomeCompareFixture, row: Int) {
        self.fixture = fixture
        super.init(frame: .zero)
        rows.segmentCount = fixture.rowTitles.count
        for (i, title) in fixture.rowTitles.enumerated() { rows.setLabel(title, forSegment: i) }
        rows.segmentStyle = .capsule
        rows.target = self
        rows.action = #selector(rowChanged)
        rows.selectedSegment = row
        compare.firstTitle = fixture.columnTitles[0]
        compare.secondTitle = fixture.columnTitles[1]
        addSubview(compare)
        addSubview(rows)
        show(row)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func show(_ row: Int) {
        compare.first = fixture.picture(row: row, column: 0)
        compare.second = fixture.picture(row: row, column: 1)
    }

    @objc private func rowChanged() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
        compare.wantsLayer = true
        compare.layer?.add(fade, forKey: "row")
        show(rows.selectedSegment)
    }

    override func layout() {
        super.layout()
        let size = rows.fittingSize
        rows.frame = CGRect(x: (bounds.midX - size.width / 2).rounded(), y: 12, width: size.width, height: size.height)
        compare.frame = CGRect(x: 16, y: rows.frame.maxY + 12, width: bounds.width - 32, height: bounds.height - rows.frame.maxY - 28)
    }
}
#endif
