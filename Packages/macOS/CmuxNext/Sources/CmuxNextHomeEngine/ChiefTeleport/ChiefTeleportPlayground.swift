#if DEBUG
public import AppKit
import CmuxNextDesign

/// DEBUG ONLY: Debug > Chief Teleport Playground. Every location chip variant
/// (``ChiefTeleportChipStyle``) in every state (on This Mac, in cmux Cloud, on a Mac mini, moving,
/// verifying, failed, rolled back), in the app's appearance (light or dark), each a live chip whose click opens its real
/// Teleport menu (picks do nothing here). Beside the grid, the menu of the state picked above, as
/// text, so a still capture shows it too. The labels are DEV-only English; the chips' own words are
/// the product's localized strings.
@MainActor
public final class ChiefTeleportPlayground: NSObject, NSWindowDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.home.chiefTeleportPlayground")

    /// One row of the grid: a state the chip can be in.
    struct Sample {
        var title: String
        var location: ChiefLocation
        var phase: ChiefTeleportPhase
        /// The header's wording for a host Home cannot open ("Chief is on …").
        var saysAway = false
    }

    static let samples: [Sample] = [
        Sample(title: "On This Mac", location: .thisMac, phase: .idle),
        Sample(title: "In cmux Cloud", location: .cloud, phase: .done("cmux Cloud")),
        Sample(title: "On a Mac mini", location: .host("cmux-mini"), phase: .idle),
        Sample(title: "On a host (header)", location: .host("gcp-linux-1"), phase: .idle, saysAway: true),
        Sample(title: "Moving", location: .thisMac, phase: .moving("cmux Cloud")),
        Sample(title: "Verifying", location: .cloud, phase: .verifying("cmux Cloud")),
        Sample(title: "Failed", location: .thisMac, phase: .failed("Mac mini", reason: "ssh: connect to host cmux-mini: timed out")),
        Sample(title: "Rolled back", location: .thisMac, phase: .rolledBack),
    ]

    static let destinations: [ChiefTeleportDestination] = [
        ChiefTeleportDestination(id: "local", title: ChiefTeleportStrings.thisMac, place: .thisMac),
        ChiefTeleportDestination(id: "ssh-mini", title: "Mac mini", place: .host("lawrence@cmux-mini")),
        ChiefTeleportDestination(id: "ssh-gcp", title: "gcp-linux-1 (offline)", place: .host("gcp-linux-1"), isAvailable: false),
        ChiefTeleportDestination(id: "cloud", title: ChiefTeleportStrings.cloud, place: .cloud),
    ]

    private let window: NSWindow
    private let statePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let menuPreview = NSStackView()
    private var chips: [ChiefTeleportChip] = []

    /// Shows the playground (one window: a second call brings it front), its menu preview on the
    /// sample at `state` (an index into the states; nil keeps the shown one).
    public static func show(state: Int? = nil) {
        let shown = NSApp.windows.first { $0.identifier == identifier }
        let playground = (shown?.contentView as? ChiefTeleportPlaygroundView)?.owner ?? ChiefTeleportPlayground()
        if let state, samples.indices.contains(state) { playground.statePicker.selectItem(at: state) }
        playground.showMenuPreview()
        playground.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.identifier = Self.identifier
        window.title = "Chief Teleport Playground"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = ChiefTeleportPlaygroundView()
        content.owner = self
        window.contentView = content
        layout(in: content)
        statePicker.selectItem(at: 1)
        window.center()
    }

    private func layout(in content: NSView) {
        for sample in Self.samples { statePicker.addItem(withTitle: "Menu for: \(sample.title)") }
        statePicker.target = self
        statePicker.action = #selector(stateChanged)
        let caption = ThemedLabel(wrappingLabelWithString:
            "Columns: chip variants (Plain ships). Rows: states. Click any chip for its real menu. Switch the app to light or dark to see both.")
        caption.font = Typography.caption
        caption.ink = .secondary
        let bar = NSStackView(views: [statePicker, caption])
        bar.spacing = 12
        let column = NSStackView(views: [bar, grid()])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
    }

    /// The grid of variants and states, and the picked state's menu.
    private func grid() -> NSView {
        var rows: [[NSView]] = [[label("State", ink: .primary)]
            + ChiefTeleportChipStyle.allCases.map { label($0.title, ink: .secondary) }]
        for sample in Self.samples {
            var row: [NSView] = [label(sample.title, ink: .secondary)]
            for style in ChiefTeleportChipStyle.allCases {
                let model = ChiefTeleportModel(showing: sample.location, phase: sample.phase, destinations: Self.destinations)
                // Picks do nothing here: the model's default actions are empty.
                let chip = ChiefTeleportChip(model: model, style: style)
                chip.saysAway = sample.saysAway
                chips.append(chip)
                row.append(chip)
            }
            rows.append(row)
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 18
        grid.yPlacement = .center
        menuPreview.orientation = .vertical
        menuPreview.alignment = .leading
        menuPreview.spacing = 3
        let split = NSStackView(views: [grid, menuPreview])
        split.alignment = .top
        split.spacing = 28
        split.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        return split
    }

    private func label(_ text: String, ink: ThemeInk) -> ThemedLabel {
        let label = ThemedLabel(labelWithString: text)
        label.font = Typography.caption
        label.ink = ink
        return label
    }

    /// The picked state's real menu items, as lines of text (✓ the current place, greyed rows dim).
    private func showMenuPreview() {
        let index = max(0, statePicker.indexOfSelectedItem)
        let sample = Self.samples[min(index, Self.samples.count - 1)]
        let model = ChiefTeleportModel(showing: sample.location, phase: sample.phase, destinations: Self.destinations)
        let menu = ChiefTeleportMenuBuilder(model: model).makeMenu()
        for view in menuPreview.arrangedSubviews { view.removeFromSuperview() }
        for item in menu.items {
            let text = item.isSeparatorItem ? "――――――――" : (item.state == .on ? "✓ " : "   ") + item.title
            let enabled = item.isEnabled && item.action != nil
            menuPreview.addArrangedSubview(label(text, ink: enabled || item.state == .on ? .primary : .tertiary))
        }
    }

    @objc private func stateChanged() { showMenuPreview() }

    public func windowWillClose(_ notification: Notification) {
        // The window lets go of the playground; nothing else holds it.
        (window.contentView as? ChiefTeleportPlaygroundView)?.owner = nil
    }
}
#endif
