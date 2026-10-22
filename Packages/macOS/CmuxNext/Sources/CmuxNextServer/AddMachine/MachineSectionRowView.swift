import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// One machine in the Machines section: its symbol, name, last-check mark, link state and a
/// New Workspace button (enabled while connected). Holds a value snapshot and one action only.
final class MachineSectionRowView: NSView {
    let row: MachineSectionRow
    private let newWorkspace: @MainActor (String) -> Void

    init(row: MachineSectionRow, newWorkspace: @escaping @MainActor (String) -> Void) {
        self.row = row
        self.newWorkspace = newWorkspace
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("cmux.rightSidebar.machines.row.\(row.id)")

        let symbol = ThemedImageView(image: NSImage(systemSymbolName: row.isLocal ? "laptopcomputer" : "cloud", accessibilityDescription: nil) ?? NSImage())
        symbol.ink = .secondary
        symbol.setContentHuggingPriority(.required, for: .horizontal)

        let name = ThemedLabel(labelWithString: row.name)
        name.font = Typography.body
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var nameViews: [NSView] = [name]
        if let mark = Self.healthMark(row.health) { nameViews.append(mark) }
        let nameLine = NSStackView(views: nameViews)
        nameLine.orientation = .horizontal
        nameLine.spacing = Metrics.space2

        let state = row.isConnected ? AddMachineStrings.connected : AddMachineStrings.offline
        let status = ThemedLabel(labelWithString: state)
        status.font = Typography.caption
        status.ink = .secondary

        let text = NSStackView(views: [nameLine, status])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setAccessibilityElement(true)
        text.setAccessibilityRole(.staticText)
        text.setAccessibilityLabel([row.name, state, row.healthHelp ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
        if let help = row.healthHelp { text.themedToolTip = help }

        let new = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: AddMachineStrings.newWorkspace) ?? NSImage(),
                           target: self, action: #selector(newClicked))
        new.isBordered = false
        new.isEnabled = row.isConnected
        new.setAccessibilityLabel(AddMachineStrings.newWorkspace)
        new.setAccessibilityIdentifier("cmux.rightSidebar.machines.new.\(row.id)")
        new.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let line = NSStackView(views: [symbol, text, spacer, new])
        line.orientation = .horizontal
        line.spacing = Metrics.panelInset
        line.edgeInsets = NSEdgeInsets(top: 3, left: Metrics.panelInset, bottom: 3, right: Metrics.panelInset)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The last check as a small mark after the name: a check when every step passed, a dot in
    /// the warning or danger color otherwise, nothing before a check ran.
    private static func healthMark(_ health: HostHealth?) -> NSView? {
        let dot = AddMachineMetrics.dotSize
        switch health {
        case .ok:
            let image = ThemedImageView(image: NSImage.icon(.statusComplete, size: dot * 2))
            image.themeTint = { Palette.success }
            return image
        case .warning:
            return MachineHealthDotView(diameter: dot) { Palette.attention }
        case .failing:
            return MachineHealthDotView(diameter: dot) { Palette.danger }
        case nil:
            return nil
        }
    }

    @objc private func newClicked() { newWorkspace(row.id) }
}
