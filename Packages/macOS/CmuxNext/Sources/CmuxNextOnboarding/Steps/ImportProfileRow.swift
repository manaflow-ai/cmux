public import AppKit
public import CmuxNextBrowserImport
public import CmuxNextCompatAppKit
import CmuxNextDesign
import CmuxNextIcons

/// Counts as "Bookmarks 1,204 · History 8,311 · Passwords 412", using the
/// kind names the checkboxes show (no per-language plural rules needed).
enum ImportCountsText {
    static func line(_ counts: ImportCounts) -> String {
        let values: [(ImportDataKind, Int)] = [(.bookmarks, counts.bookmarks), (.history, counts.history),
                                               (.openTabs, counts.openTabs), (.cookies, counts.cookies), (.passwords, counts.passwords)]
        // One default engine per profile: its name alone says it came over.
        let engine = counts.searchEngines > 0 ? [OnboardingStrings.kind(.searchEngines)] : []
        return (values.filter { $0.1 > 0 }.map { "\(OnboardingStrings.kind($0.0)) \($0.1.formatted(.number))" } + engine)
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
    private let box = ThemedCheckbox(checkboxWithTitle: "", target: nil, action: nil)
    /// The shared themed spinner, in phase with every other one (cx-qtgj2).
    private let spinner = StatusIndicatorView.spinner()
    private let detail = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary)
    private let mark = NSImageView()
    private let icon = NSImageView()
    private let avatar = NSImageView()
    private let name = OnboardingLabel.make(font: OnboardingMetrics.bodyFont)
    private let sub = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary)
    private let names = NSStackView()
    private let accessButton: NSButton
    /// Which cmux profile the row goes into: its own new one, or one that exists.
    private let targetMenu = ThemedPopUpButton(frame: .zero, pullsDown: false)
    private var targetIDs: [String?] = []
    private var onTarget: ((String?) -> Void)?
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
        targetMenu.controlSize = .small
        targetMenu.font = OnboardingMetrics.captionFont
        targetMenu.target = self
        targetMenu.action = #selector(targetPicked)
        targetMenu.setAccessibilityLabel(OnboardingStrings.importInto)
        targetMenu.setAccessibilityIdentifier("cmux.onboarding.import.target")
        NSLayoutConstraint.activate([spinner.widthAnchor.constraint(equalToConstant: 16), spinner.heightAnchor.constraint(equalToConstant: 16)])
        detail.alignment = .right
        let spinnerSlot = Self.slot(width: 18, containing: spinner)
        let markSlot = Self.slot(width: 18, containing: mark)
        let accessSlot = Self.slot(width: 132, containing: accessButton)
        let boxSlot = Self.slot(width: 20, containing: box)
        targetMenu.translatesAutoresizingMaskIntoConstraints = false
        targetMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true
        let trailing = NSStackView(views: [detail, targetMenu, spinnerSlot, markSlot, accessSlot, boxSlot])
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

    convenience init(profile: BrowserSourceProfile, icon: NSImage?, needsFullDiskAccess: Bool = false,
                     onAccess: (() -> Void)? = nil, toggle: @escaping () -> Void) {
        self.init(toggle: toggle)
        configure(profile: profile, icon: icon, needsFullDiskAccess: needsFullDiskAccess,
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

    func configure(profile: BrowserSourceProfile, icon browserIcon: NSImage?, needsFullDiskAccess: Bool = false,
                   onAccess: (() -> Void)? = nil, toggle: @escaping () -> Void) {
        self.toggle = toggle
        self.onAccess = onAccess
        requiresFullDiskAccess = needsFullDiskAccess || profile.needsFullDiskAccess
        configured = true
        (accessButton as? OnboardingTextButton)?.setPlainTitle(OnboardingStrings.openSystemSettings)
        icon.image = browserIcon ?? Self.placeholder
        avatar.image = profile.avatar.flatMap { try? Data(blockingContentsOf: $0) }.flatMap { blockingNSImage($0) }
        avatar.alphaValue = avatar.image == nil ? 0 : 1
        name.stringValue = profile.browser.displayName
        let showsProfile = !(profile.directoryName.isEmpty || profile.browser.family == .safari || profile.browser.family.isPrivateStore)
        let subtitle = requiresFullDiskAccess ? OnboardingStrings.fullDiskAccessSubtitle : (showsProfile ? profile.displayName : "")
        sub.stringValue = subtitle
        sub.alphaValue = subtitle.isEmpty ? 0 : 1
        box.setAccessibilityLabel(OnboardingStrings.profileName(profile))
        alphaValue = 1
        update(checked: false, editable: true, state: .idle)
    }

    /// A browser whose profile folder cmux has no grant for: its icon and
    /// name, "No access yet", and Allow Access… (the grant explainer).
    func configureAwaiting(_ browser: ImportBrowser, icon browserIcon: NSImage?, onAccess: @escaping () -> Void) {
        toggle = nil
        self.onAccess = onAccess
        requiresFullDiskAccess = true
        configured = true
        (accessButton as? OnboardingTextButton)?.setPlainTitle(OnboardingStrings.allowAccess)
        icon.image = browserIcon ?? Self.placeholder
        avatar.image = nil
        avatar.alphaValue = 0
        name.stringValue = browser.displayName
        sub.stringValue = OnboardingStrings.accessNeeded
        sub.alphaValue = 1
        box.setAccessibilityLabel(browser.displayName)
        configureTargets([], selected: nil, onPick: nil)
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
        spinner.spin(false)
        configureTargets([], selected: nil, onPick: nil)
        targetMenu.isHidden = true
    }

    /// What a row shows until its browser's icon lands (``ImportStepModel/browserIcons``), and for a browser with
    /// no app.
    static var placeholder: NSImage { NSImage.icon(.browser, size: 16) }

    /// The cmux profiles this row can go into: "New Profile" (its own,
    /// matching the source) first, then each existing one; `selected` is
    /// checked. No choices hides the menu (the step imports into one profile).
    func configureTargets(_ choices: [ImportTargetChoice], selected: String?, onPick: ((String?) -> Void)?) {
        onTarget = onPick
        let ids: [String?] = onPick == nil || choices.isEmpty ? [] : [nil] + choices.map(\.id)
        if ids != targetIDs || targetMenu.numberOfItems != ids.count {
            targetIDs = ids
            targetMenu.removeAllItems()
            guard !ids.isEmpty else { return }
            targetMenu.addItem(withTitle: OnboardingStrings.newMatchingProfile)
            for choice in choices { targetMenu.addItem(withTitle: choice.name) }
        }
        targetMenu.selectItem(at: targetIDs.firstIndex(of: selected) ?? 0)
    }

    @objc private func targetPicked() {
        let index = targetMenu.indexOfSelectedItem
        guard targetIDs.indices.contains(index) else { return }
        onTarget?(targetIDs[index])
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

    // visibility-walk-allow: repaints its hover fill (ChromeHover) only, no layout
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
        var markIcon: IconName?
        detail.themedToolTip = nil
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
            markIcon = .statusComplete
            detail.stringValue = ImportCountsText.line(counts)
        case .failed(let reason):
            markIcon = .statusError
            detail.stringValue = OnboardingStrings.importRowFailed
            detail.themedToolTip = reason
        }
        box.alphaValue = showsBox ? 1 : 0
        // Only while the row can still change; once it runs, the detail says where it went.
        targetMenu.isHidden = !(showsBox && editable && checked && !targetIDs.isEmpty)
        spinner.spin(spins)
        spinner.alphaValue = spins ? 1 : 0
        mark.image = markIcon.map { NSImage.icon($0, size: 14) }
        mark.contentTintColor = Palette.textSecondary
        mark.alphaValue = markIcon == nil ? 0 : 1
        alphaValue = showsBox && !checked ? 0.55 : 1
    }
}

extension ImportBrowser {
    /// This browser's own icon: the app at `appURL`, else its app by bundle id (for rows restored from a data folder,
    /// so Helium does not fall back to a globe when detection missed its application URL), else the app at
    /// `/Applications/<name>.app`; nil with none. Blocking (Launch Services and the disk): run it on the system lane.
    public nonisolated func appIcon(installedAt appURL: URL?, _ system: any WorkspaceQuerying) -> NSImage? {
        if let appURL { return system.fileIcon(atPath: appURL.path) }
        if let found = bundleIDs.lazy.compactMap({ system.application(withBundleIdentifier: $0) }).first {
            return system.fileIcon(atPath: found.path)
        }
        let conventionalURL = URL(fileURLWithPath: "/Applications/\(displayName).app")
        return FileManager.checked.fileExists(atPath: conventionalURL.path) ? system.fileIcon(atPath: conventionalURL.path) : nil
    }
}
