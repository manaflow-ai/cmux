import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// Counts as "Bookmarks 1,204 · History 8,311 · Passwords 412", using the
/// kind names the checkboxes show (no per-language plural rules needed).
enum ImportCountsText {
    static func line(_ counts: ImportCounts) -> String {
        let values: [(ImportDataKind, Int)] = [(.bookmarks, counts.bookmarks), (.history, counts.history),
                                               (.openTabs, counts.openTabs), (.cookies, counts.cookies), (.passwords, counts.passwords)]
        return values.filter { $0.1 > 0 }
            .map { "\(OnboardingStrings.kind($0.0)) \($0.1.formatted(.number))" }
            .joined(separator: " · ")
    }
}

/// One browser profile: the browser's icon with the profile's picture on
/// it, the browser and profile names, and on the right a checkbox, the
/// running kind, or what came over. Clicking anywhere on the row toggles it;
/// an editable row shows the shared hover and pressed fill (`ChromeHover`).
final class ImportProfileRow: NSView {
    static let height: CGFloat = 44
    private let toggle: () -> Void
    private let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let detail = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary)
    private let mark = NSImageView()
    private var editable = true
    private(set) lazy var hover = ChromeHover(self, tracking: .activeInKeyWindow)

    init(profile: BrowserSourceProfile, appURL: URL?, toggle: @escaping () -> Void) {
        self.toggle = toggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: Self.icon(appURL))
        icon.imageScaling = .scaleProportionallyUpOrDown
        let avatar = NSImageView()
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 8
        avatar.layer?.masksToBounds = true
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.image = profile.avatar.flatMap { NSImage(contentsOf: $0) }
        avatar.isHidden = avatar.image == nil
        let name = OnboardingLabel.make(profile.browser.displayName)
        let showsProfile = !(profile.directoryName.isEmpty || profile.browser.family == .safari || profile.browser.family == .webkit)
        let sub = OnboardingLabel.make(showsProfile ? profile.displayName : "", font: OnboardingMetrics.captionFont, color: Palette.textSecondary)
        sub.isHidden = !showsProfile
        let names = NSStackView(views: [name, sub])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        box.target = self
        box.action = #selector(boxPressed)
        box.setAccessibilityLabel(OnboardingStrings.profileName(profile))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        mark.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        detail.alignment = .right
        let trailing = NSStackView(views: [detail, spinner, mark, box])
        trailing.spacing = 8
        for view in [icon, avatar, names, trailing] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30), icon.heightAnchor.constraint(equalToConstant: 30),
            avatar.trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            avatar.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3),
            avatar.widthAnchor.constraint(equalToConstant: 16), avatar.heightAnchor.constraint(equalToConstant: 16),
            names.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12), names.centerYAnchor.constraint(equalTo: centerYAnchor),
            names.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The installed browser's own icon; a globe when the app is gone (its data folder is still there).
    static func icon(_ appURL: URL?) -> NSImage {
        if let appURL { return NSWorkspace.shared.icon(forFile: appURL.path) }
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
    }

    @objc private func boxPressed() { toggle() }

    override func layout() {
        super.layout()
        hover.layout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { if editable { hover.state.hovering = true } }
    override func mouseExited(with event: NSEvent) { hover.state.hovering = false }

    override func mouseDown(with event: NSEvent) {
        guard editable else { return }
        hover.state.pressed = true
    }

    /// Toggles on release inside the row, as a button does.
    override func mouseUp(with event: NSEvent) {
        guard hover.state.pressed else { return }
        hover.state.pressed = false
        if editable, bounds.contains(convert(event.locationInWindow, from: nil)) { toggle() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hover.refresh(animated: false)
    }

    func update(checked: Bool, editable: Bool, state: ImportStepModel.RowState) {
        self.editable = editable
        if !editable { hover.state = ChromeHover.State() }
        box.state = checked ? .on : .off
        box.isEnabled = editable
        var showsBox = false
        var spins = false
        var symbol: String?
        detail.toolTip = nil
        switch state {
        case .idle:
            showsBox = true
            detail.stringValue = ""
        case .waiting:
            detail.stringValue = OnboardingStrings.importWaiting
        case .importing(let kind, let counts):
            spins = true
            let running = ImportCountsText.line(counts)
            detail.stringValue = running.isEmpty ? kind.map(OnboardingStrings.kind) ?? "" : running
        case .done(let counts):
            symbol = "checkmark.circle.fill"
            detail.stringValue = ImportCountsText.line(counts)
        case .failed(let reason):
            symbol = "exclamationmark.triangle.fill"
            detail.stringValue = OnboardingStrings.importRowFailed
            detail.toolTip = reason
        }
        box.isHidden = !showsBox
        if spins { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        mark.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        mark.contentTintColor = Palette.textSecondary
        mark.isHidden = symbol == nil
        alphaValue = showsBox && !checked ? 0.55 : 1
    }
}
