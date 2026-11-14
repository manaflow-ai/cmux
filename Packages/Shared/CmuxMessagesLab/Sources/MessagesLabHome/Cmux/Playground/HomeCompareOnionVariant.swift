#if DEBUG
import AppKit

/// DEBUG ONLY: playground variant 3, onion skin: After laid over Before at the opacity of a slider (0 shows
/// Before, 1 After), so a moved edge shows as a ghost of itself. A Light | Dark switch picks the pair.
@MainActor
final class HomeCompareOnionVariant: NSView {
    private let fixture: HomeCompareFixture
    private let below = CALayer()
    private let above = CALayer()
    private let stage = NSView(frame: .zero)
    private let opacity = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let rows = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
    private let before = NSTextField(labelWithString: "")
    private let after = NSTextField(labelWithString: "")

    init(fixture: HomeCompareFixture, row: Int) {
        self.fixture = fixture
        super.init(frame: .zero)
        stage.wantsLayer = true
        for l in [below, above] {
            l.contentsGravity = .resizeAspect
            l.actions = ["contents": NSNull(), "opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
            stage.layer?.addSublayer(l)
        }
        rows.segmentCount = fixture.rowTitles.count
        for (i, title) in fixture.rowTitles.enumerated() { rows.setLabel(title, forSegment: i) }
        rows.segmentStyle = .capsule
        rows.target = self
        rows.action = #selector(changed)
        rows.selectedSegment = row
        opacity.target = self
        opacity.action = #selector(changed)
        opacity.isContinuous = true
        before.stringValue = fixture.columnTitles[0]
        after.stringValue = fixture.columnTitles[1]
        for v in [stage, rows, opacity, before, after] as [NSView] { addSubview(v) }
        changed()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    @objc private func changed() {
        below.contents = fixture.picture(row: rows.selectedSegment, column: 0)
        above.contents = fixture.picture(row: rows.selectedSegment, column: 1)
        above.opacity = Float(opacity.doubleValue)
    }

    override func layout() {
        super.layout()
        let r = rows.fittingSize
        rows.frame = CGRect(x: (bounds.midX - r.width / 2).rounded(), y: 12, width: r.width, height: r.height)
        let barY = bounds.height - 36
        before.sizeToFit()
        after.sizeToFit()
        before.frame.origin = CGPoint(x: bounds.midX - 180 - before.frame.width - 8, y: barY + 2)
        opacity.frame = CGRect(x: bounds.midX - 180, y: barY, width: 360, height: 22)
        after.frame.origin = CGPoint(x: bounds.midX + 188, y: barY + 2)
        stage.frame = CGRect(x: 16, y: rows.frame.maxY + 12, width: bounds.width - 32, height: barY - rows.frame.maxY - 24)
        below.frame = stage.bounds
        above.frame = stage.bounds
    }
}
#endif
