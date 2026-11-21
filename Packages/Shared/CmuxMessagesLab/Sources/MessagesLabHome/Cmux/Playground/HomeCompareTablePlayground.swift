#if DEBUG
public import AppKit

/// DEBUG ONLY: Debug > Before/After Table Playground (the user, 2026-11-05, msg 23164: "come up with more design
/// variations of this so it can be better"; design playgrounds are Swift, live in the real app, 2026-11-02).
/// One window with seven ways to show a Before|After × Light|Dark table, each live: 1 slider with a Light | Dark
/// switch (the default the picture viewer opens on), 2 Before | After toggle with a crossfade, 3 onion skin,
/// 4 side by side with synced zoom, 5 filmstrip, 6 the chat card's large pairs (Home's default) and 7 the plain
/// grid. The labels are DEV-only English.
@MainActor
public final class HomeCompareTablePlayground: NSObject {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.home.compareTablePlayground")
    /// The variants' names, in the picker's order.
    static let variants = ["Slider + Light/Dark", "Toggle", "Onion Skin", "Synced Zoom", "Filmstrip", "Chat Card: Large Pairs", "Chat Card: Grid"]

    private let window: NSWindow
    private let picker = NSSegmentedControl(labels: HomeCompareTablePlayground.variants, trackingMode: .selectOne, target: nil, action: nil)
    private let appearance = NSSegmentedControl(labels: ["Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil)
    private let stage = NSView(frame: .zero)
    private let fixture = HomeCompareFixture()
    private lazy var table: HomeTable? = fixture.table(in: HomeMedia.directory)
    private var row = 0

    /// Shows the playground (one window) on variant `variant` (1...7), its picture set `row` (0 Light, 1 Dark)
    /// and the window's look (`dark`); nil keeps what it shows.
    public static func show(variant: Int? = nil, row: Int? = nil, dark: Bool? = nil) {
        let open = NSApp.windows.first { $0.identifier == identifier }
        let playground = (open?.contentView as? HomeComparePlaygroundContent)?.owner ?? HomeCompareTablePlayground()
        if let row { playground.row = min(max(0, row), 1) }
        if let dark { playground.appearance.selectedSegment = dark ? 1 : 0 }
        if let variant { playground.picker.selectedSegment = min(max(1, variant), variants.count) - 1 }
        playground.apply()
        playground.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.identifier = Self.identifier
        window.title = "Before/After Table Playground"
        window.isReleasedWhenClosed = false
        let content = HomeComparePlaygroundContent(frame: window.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        for control in [picker, appearance] {
            control.segmentStyle = .rounded
            control.target = self
            control.action = #selector(controlChanged)
            content.addSubview(control)
        }
        picker.selectedSegment = 0
        appearance.selectedSegment = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 1 : 0
        content.addSubview(stage)
        content.picker = picker
        content.appearanceSwitch = appearance
        content.stage = stage
        content.owner = self
        window.contentView = content
        window.center()
    }

    @objc private func controlChanged() { apply() }

    private func apply() {
        window.appearance = NSAppearance(named: appearance.selectedSegment == 1 ? .darkAqua : .aqua)
        for v in stage.subviews { v.removeFromSuperview() }
        let view: NSView = switch picker.selectedSegment {
        case 1: HomeCompareToggleVariant(fixture: fixture, row: row)
        case 2: HomeCompareOnionVariant(fixture: fixture, row: row)
        case 3: HomeCompareSyncedZoomVariant(fixture: fixture, row: row)
        case 4: HomeCompareFilmstripVariant(fixture: fixture, row: row)
        case 5: HomeCompareCardVariant(table: table, style: .pairs)
        case 6: HomeCompareCardVariant(table: table, style: .grid)
        default: HomeCompareSliderVariant(fixture: fixture, row: row)
        }
        view.frame = stage.bounds
        view.autoresizingMask = [.width, .height]
        stage.addSubview(view)
        window.makeFirstResponder(view)
    }
}
#endif
