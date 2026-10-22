import AppKit
import CmuxAgentBrands
import CmuxNextActions
import CmuxNextDesign

/// One session of the vault list: the agent's mark, title, folder and last activity. A click
/// selects it, a double click opens it, a right-click shows its actions. Holds a value snapshot
/// and the action bundle only.
final class VaultRowView: NSView, NSMenuDelegate {
    let row: VaultRow
    private let actions: VaultRowActions
    private let colors: VaultColors
    private let ago = NSTextField(labelWithString: "")

    init(row: VaultRow, isSelected: Bool, colors: VaultColors, actions: VaultRowActions) {
        self.row = row
        self.actions = actions
        self.colors = colors
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = isSelected ? colors.selection.cgColor : NSColor.clear.cgColor
        setAccessibilityIdentifier("cmux.vault.row")
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel([row.title, row.detail].compactMap { $0 }.joined(separator: ", "))
        setAccessibilitySelected(isSelected)
        themedToolTip = row.session.cwd ?? row.title

        let mark = NSImageView(image: AgentBrandCatalog.templateImage(brand: row.session.provider, size: Metrics.iconSize) ?? NSImage())
        mark.contentTintColor = colors.secondary
        mark.setContentHuggingPriority(.required, for: .horizontal)
        let title = NSTextField(labelWithString: row.title)
        title.font = Typography.body
        title.textColor = colors.primary
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var lines: [NSView] = [title]
        if let detail = row.detail {
            let label = NSTextField(labelWithString: detail)
            label.font = Typography.caption
            label.textColor = colors.tertiary
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            lines.append(label)
        }
        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [mark, text, spacer]
        if row.isLive {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = colors.live.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            dot.themedToolTip = VaultStrings.running
            views.append(dot)
        }
        ago.font = .monospacedDigitSystemFont(ofSize: TypeScale.caption, weight: TypeScale.regular)
        ago.textColor = colors.tertiary
        ago.setContentHuggingPriority(.required, for: .horizontal)
        ago.setContentCompressionResistancePriority(.required, for: .horizontal)
        views.append(ago)
        refreshAgo()
        let line = NSStackView(views: views)
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
        let menu = NSMenu()
        menu.delegate = self
        self.menu = menu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The last activity, relative to now ("2 min ago"); the list refreshes it when it reloads.
    func refreshAgo(now: Date = .now) {
        ago.stringValue = RelativeDateTimeFormatter().localizedString(for: row.session.lastActivityAt, relativeTo: now)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate(clickCount: event.clickCount)
    }

    /// A click selects the row; a second click of a double click opens the session.
    func activate(clickCount: Int) {
        if clickCount >= 2 { actions.perform("vaultOpenSession", row.id) } else { actions.select(row.id) }
    }

    override func accessibilityPerformPress() -> Bool {
        actions.perform("vaultOpenSession", row.id)
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ id: ActionID, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? #selector(menuPicked(_:)) : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = id.rawValue
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if row.isLive { add(VaultStrings.focusSession, "vaultFocusSession") }
        add(VaultStrings.openSession, "vaultOpenSession", enabled: row.canResume)
        add(VaultStrings.resumeInNewWorkspace, "vaultResumeInNewWorkspace", enabled: row.canResume)
        menu.addItem(.separator())
        add(VaultStrings.copyResumeCommand, "vaultCopyResumeCommand", enabled: row.canResume)
        add(VaultStrings.openPullRequest, "vaultOpenPullRequest")
    }

    @objc private func menuPicked(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        actions.perform(ActionID(rawValue: id), row.id)
    }
}
