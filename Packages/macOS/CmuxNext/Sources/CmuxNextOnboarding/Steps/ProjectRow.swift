import AppKit
import CmuxNextDesign

/// One project: a folder symbol, the folder's name over its path, then how
/// much the agents used it (sessions, last time, which agents) and a
/// checkbox. Clicking anywhere on the row toggles it, over the shared hover
/// and pressed fill (`OnboardingHover`). The icon is a symbol, not the
/// folder's own icon: reading that would raise a privacy prompt for a
/// folder on the Desktop.
final class ProjectRow: NSView {
    static let height: CGFloat = 40
    private let toggle: () -> Void
    private let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private(set) lazy var hover = OnboardingHover(self, outset: NSSize(width: 6, height: 0))

    init(project: AgentProject, home: URL, now: Date, toggle: @escaping () -> Void) {
        self.toggle = toggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.contentTintColor = Palette.textSecondary
        let name = OnboardingLabel.make(project.folder.lastPathComponent)
        let path = OnboardingLabel.make(Self.shortPath(project.folder, home: home), font: OnboardingMetrics.captionFont, color: Palette.textSecondary)
        path.lineBreakMode = .byTruncatingMiddle
        let names = NSStackView(views: [name, path])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        let usage = OnboardingLabel.make(Self.usage(project, now: now), font: OnboardingMetrics.captionFont, color: Palette.textSecondary)
        usage.alignment = .right
        usage.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        usage.toolTip = project.sessions > 0 ? OnboardingStrings.projectsSessions(project.sessions) : nil
        box.target = self
        box.action = #selector(boxPressed)
        box.setAccessibilityLabel(project.folder.lastPathComponent)
        for view in [icon, names, usage, box] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            names.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), names.centerYAnchor.constraint(equalTo: centerYAnchor),
            names.trailingAnchor.constraint(lessThanOrEqualTo: usage.leadingAnchor, constant: -12),
            usage.trailingAnchor.constraint(equalTo: box.leadingAnchor, constant: -10), usage.centerYAnchor.constraint(equalTo: centerYAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), box.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `~/code/app` for a folder in the home folder, else the full path.
    static func shortPath(_ folder: URL, home: URL) -> String {
        let path = folder.path
        let homePath = home.standardizedFileURL.path
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    /// "148 · 2 days ago · Claude Code, Codex"; a chosen folder has none of these.
    static func usage(_ project: AgentProject, now: Date) -> String {
        guard project.sessions > 0 else { return "" }
        let when = RelativeDateTimeFormatter().localizedString(for: project.lastActive, relativeTo: now)
        let apps = ListFormatter.localizedString(byJoining: project.apps.map(\.displayName))
        return ["\(project.sessions.formatted(.number))", when, apps].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @objc private func boxPressed() { toggle() }

    func update(checked: Bool) {
        box.state = checked ? .on : .off
    }

    override func layout() {
        super.layout()
        hover.layout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hover.state.hovering = true }
    override func mouseExited(with event: NSEvent) { hover.state = OnboardingHover.State() }
    override func mouseDown(with event: NSEvent) { hover.state.pressed = true }

    /// Toggles on release inside the row, as a button does.
    override func mouseUp(with event: NSEvent) {
        guard hover.state.pressed else { return }
        hover.state.pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { toggle() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hover.refresh(animated: false)
    }
}
