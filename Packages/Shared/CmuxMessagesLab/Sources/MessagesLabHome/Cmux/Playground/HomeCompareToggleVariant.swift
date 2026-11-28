#if DEBUG
import AppKit

/// DEBUG ONLY: playground variant 2: one picture at a time at the stage's full size; a Before | After switch,
/// a click on the picture or Space flips it with a quick crossfade (none with Reduce Motion), so the eye sees
/// only what changed. A Light | Dark switch picks the pair.
@MainActor
final class HomeCompareToggleVariant: NSView {
    private let fixture: HomeCompareFixture
    private let picture = NSImageView(frame: .zero)
    private let side = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
    private let rows = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)

    init(fixture: HomeCompareFixture, row: Int) {
        self.fixture = fixture
        super.init(frame: .zero)
        for (control, titles) in [(side, fixture.columnTitles), (rows, fixture.rowTitles)] {
            control.segmentCount = titles.count
            for (i, title) in titles.enumerated() { control.setLabel(title, forSegment: i) }
            control.segmentStyle = .capsule
            control.target = self
            control.action = #selector(changed)
            control.selectedSegment = 0
            addSubview(control)
        }
        rows.selectedSegment = row
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        addSubview(picture)
        show(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func show(animated: Bool) {
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            picture.layer?.add(fade, forKey: "flip")
        }
        picture.image = fixture.picture(row: rows.selectedSegment, column: side.selectedSegment)
            .map { NSImage(cgImage: $0, size: NSSize(width: $0.width / 2, height: $0.height / 2)) }
    }

    private func flip() {
        side.selectedSegment = 1 - side.selectedSegment
        show(animated: true)
    }

    @objc private func changed() { show(animated: true) }
    override func mouseDown(with event: NSEvent) { flip() }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { flip() } else { super.keyDown(with: event) }
    }

    override func layout() {
        super.layout()
        let s = side.fittingSize, r = rows.fittingSize
        let total = s.width + 16 + r.width
        side.frame = CGRect(x: (bounds.midX - total / 2).rounded(), y: 12, width: s.width, height: s.height)
        rows.frame = CGRect(x: side.frame.maxX + 16, y: 12, width: r.width, height: r.height)
        picture.frame = CGRect(x: 16, y: side.frame.maxY + 12, width: bounds.width - 32, height: bounds.height - side.frame.maxY - 28)
    }
}
#endif
