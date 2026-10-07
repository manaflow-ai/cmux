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
    private var toggle: (() -> Void)?
    private let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let detail = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary)
    private let mark = NSImageView()
    private let icon = NSImageView()
    private let avatar = NSImageView()
    private let name = OnboardingLabel.make(font: OnboardingMetrics.bodyFont)
    private let sub = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary)
    private let names = NSStackView()
    private let accessButton: NSButton
    private var requiresFullDiskAccess = false
    private var onAccess: (() -> Void)?
    private var configured = false
    private var editable = true
    private(set) lazy var hover = ChromeHover(self, tracking: .activeInKeyWindow)

    init(toggle: (() -> Void)?) {
        self.toggle = toggle
        accessButton = OnboardingControl.plainButton(OnboardingStrings.openSystemSettings, target: nil, action: #selector(accessPressed))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 8
        avatar.layer?.masksToBounds = true
        avatar.imageScaling = .scaleProportionallyUpOrDown
        names.addArrangedSubview(name)
        names.addArrangedSubview(sub)
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        box.target = self
        box.action = #selector(boxPressed)
        accessButton.target = self
        accessButton.controlSize = .small
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        mark.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        detail.alignment = .right
        let spinnerSlot = Self.slot(width: 18, containing: spinner)
        let markSlot = Self.slot(width: 18, containing: mark)
        let accessSlot = Self.slot(width: 132, containing: accessButton)
        let boxSlot = Self.slot(width: 20, containing: box)
        let trailing = NSStackView(views: [detail, spinnerSlot, markSlot, accessSlot, boxSlot])
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
        clearProfile()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    convenience init(profile: BrowserSourceProfile, appURL: URL?, needsFullDiskAccess: Bool = false,
                     onAccess: (() -> Void)? = nil, toggle: @escaping () -> Void) {
        self.init(toggle: toggle)
        configure(profile: profile, appURL: appURL, needsFullDiskAccess: needsFullDiskAccess,
                  onAccess: onAccess, toggle: toggle)
    }

    private static func slot(width: CGFloat, containing view: NSView) -> NSView {
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(view)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: width),
            view.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: slot.leadingAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: slot.trailingAnchor),
        ])
        return slot
    }

    func configure(profile: BrowserSourceProfile, appURL: URL?, needsFullDiskAccess: Bool = false,
                   onAccess: (() -> Void)? = nil, toggle: @escaping () -> Void) {
        self.toggle = toggle
        self.onAccess = onAccess
        requiresFullDiskAccess = needsFullDiskAccess || profile.needsFullDiskAccess
        configured = true
        icon.image = Self.icon(appURL, browser: profile.browser)
        avatar.image = profile.avatar.flatMap { NSImage(contentsOf: $0) }
        avatar.alphaValue = avatar.image == nil ? 0 : 1
        name.stringValue = profile.browser.displayName
        let showsProfile = !(profile.directoryName.isEmpty || profile.browser.family == .safari || profile.browser.family == .webkit)
        let subtitle = requiresFullDiskAccess ? OnboardingStrings.fullDiskAccessSubtitle : (showsProfile ? profile.displayName : "")
        sub.stringValue = subtitle
        sub.alphaValue = subtitle.isEmpty ? 0 : 1
        box.setAccessibilityLabel(OnboardingStrings.profileName(profile))
        alphaValue = 1
        update(checked: false, editable: true, state: .idle)
    }

    func clearProfile() {
        configured = false
        toggle = nil
        onAccess = nil
        requiresFullDiskAccess = false
        editable = false
        name.stringValue = ""
        sub.stringValue = ""
        detail.stringValue = ""
        icon.image = nil
        avatar.image = nil
        avatar.alphaValue = 0
        alphaValue = 0
        box.alphaValue = 0
        accessButton.alphaValue = 0
        spinner.alphaValue = 0
        mark.alphaValue = 0
        spinner.stopAnimation(nil)
    }

    /// The installed browser's own icon. Resolve the bundle again for rows
    /// restored from a data folder so Helium does not fall back to a globe
    /// when detection missed its application URL.
    static func icon(_ appURL: URL?, browser: ImportBrowser = .chrome) -> NSImage {
        if let appURL { return NSWorkspace.shared.icon(forFile: appURL.path) }
        for bundleID in browser.bundleIDs {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: appURL.path)
            }
        }
        let conventionalURL = URL(fileURLWithPath: "/Applications/\(browser.displayName).app")
        if FileManager.default.fileExists(atPath: conventionalURL.path) {
            return NSWorkspace.shared.icon(forFile: conventionalURL.path)
        }
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
    }

    @objc private func boxPressed() { toggle?() }
    @objc private func accessPressed() { onAccess?() }

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
        if editable, bounds.contains(convert(event.locationInWindow, from: nil)) { toggle?() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hover.refresh(animated: false)
    }

    func update(checked: Bool, editable: Bool, state: ImportStepModel.RowState) {
        guard configured else { return }
        let showsAccess = requiresFullDiskAccess && state == .idle
        self.editable = editable && !requiresFullDiskAccess
        if !self.editable { hover.state = ChromeHover.State() }
        box.state = checked ? .on : .off
        box.isEnabled = editable && !requiresFullDiskAccess
        accessButton.isEnabled = showsAccess
        accessButton.alphaValue = showsAccess ? 1 : 0
        var showsBox = false
        var spins = false
        var symbol: String?
        detail.toolTip = nil
        switch state {
        case .idle:
            showsBox = !showsAccess
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
        box.alphaValue = showsBox ? 1 : 0
        if spins { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.alphaValue = spins ? 1 : 0
        mark.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        mark.contentTintColor = Palette.textSecondary
        mark.alphaValue = symbol == nil ? 0 : 1
        alphaValue = showsBox && !checked ? 0.55 : 1
    }
}
