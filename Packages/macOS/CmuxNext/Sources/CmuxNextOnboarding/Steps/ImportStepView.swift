import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// Import: one row per detected browser profile (the browser's own icon,
/// the profile's picture and name, a checkbox), then one line of what to
/// bring. Import runs in place: each row shows its progress, then what came
/// over; the line under the list sums it up.
final class ImportStepView: NSView {
    private let model: ImportStepModel
    private let list = NSStackView()
    private let kinds = NSStackView()
    private let status = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textTertiary, lines: 2)
    private let access = NSStackView()
    private var rows: [String: ImportProfileRow] = [:]
    private var kindBoxes: [ImportDataKind: NSButton] = [:]
    private var shownProfiles: [BrowserSourceProfile]?
    private var loop: RenderLoop?

    init(model: ImportStepModel) {
        self.model = model
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        kinds.spacing = 20
        for kind in ImportStepModel.offeredKinds {
            let box = OnboardingControl.checkbox(OnboardingStrings.kind(kind), target: self, action: #selector(kindToggled(_:)))
            box.tag = ImportStepModel.offeredKinds.firstIndex(of: kind) ?? 0
            kindBoxes[kind] = box
            kinds.addArrangedSubview(box)
        }
        let open = OnboardingControl.button(OnboardingStrings.openSystemSettings, target: self, action: #selector(openSettings))
        let recheck = OnboardingControl.plainButton(OnboardingStrings.checkAgain, target: self, action: #selector(recheck))
        access.setViews([OnboardingLabel.make(OnboardingStrings.fullDiskAccessTitle, color: Palette.textSecondary), open, recheck], in: .leading)
        access.spacing = 12
        let separator = ThemedView()
        separator.fill = { Palette.separator }
        let stack = NSStackView(views: [scroll, separator, kinds, status, access])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 4 * ImportProfileRow.height + 6),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor), list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor), list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor), separator.heightAnchor.constraint(equalToConstant: 1),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func kindToggled(_ sender: NSButton) { model.toggle(ImportStepModel.offeredKinds[sender.tag]) }
    @objc private func openSettings() { model.openFullDiskAccessSettings() }
    @objc private func recheck() { model.redetect() }

    private func render() {
        let profiles = model.profiles
        if profiles != shownProfiles {
            shownProfiles = profiles
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            rows = [:]
            let apps = Dictionary(model.sources.map { ($0.browser, $0.appURL) }, uniquingKeysWith: { first, _ in first })
            for profile in profiles {
                let row = ImportProfileRow(profile: profile, appURL: apps[profile.browser] ?? nil) { [weak model] in model?.toggle(profile) }
                rows[profile.id] = row
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }
        let editable = model.canEditSelection
        for profile in profiles {
            rows[profile.id]?.update(checked: model.isSelected(profile), editable: editable, state: model.rowState(profile))
        }
        for (kind, box) in kindBoxes {
            box.state = model.kinds.contains(kind) ? .on : .off
            box.isEnabled = editable
        }
        access.isHidden = !model.needsFullDiskAccess
        status.stringValue = statusText(profiles)
    }

    private func statusText(_ profiles: [BrowserSourceProfile]) -> String {
        switch model.phase {
        case .idle, .detecting: return OnboardingStrings.detecting
        case .importing: return ""
        case .finished(let summary):
            let counts = ImportCountsText.line(summary.counts)
            let line = counts.isEmpty ? OnboardingStrings.importedNothing : OnboardingStrings.imported(counts)
            return summary.failures.isEmpty ? line : line + " " + OnboardingStrings.importSomeFailed
        case .failed(let message): return message
        default:
            return profiles.isEmpty ? OnboardingStrings.noBrowsers
                : (model.kinds.contains(.cookies) ? OnboardingStrings.keychainNote : "")
        }
    }
}

/// Counts as "Bookmarks 1,204 · History 8,311 · Sign-ins 412", using the
/// kind names the checkboxes show (no per-language plural rules needed).
enum ImportCountsText {
    static func line(_ counts: ImportCounts) -> String {
        let values: [(ImportDataKind, Int)] = [(.bookmarks, counts.bookmarks), (.history, counts.history),
                                               (.openTabs, counts.openTabs), (.cookies, counts.cookies)]
        return values.filter { $0.1 > 0 }
            .map { "\(OnboardingStrings.kind($0.0)) \($0.1.formatted(.number))" }
            .joined(separator: " · ")
    }
}

/// One browser profile: the browser's icon with the profile's picture on
/// it, the browser and profile names, and on the right a checkbox, the
/// running kind, or what came over. Clicking anywhere on the row toggles it.
final class ImportProfileRow: NSView {
    static let height: CGFloat = 44
    private let toggle: () -> Void
    private let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let detail = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary)
    private let mark = NSImageView()
    private var editable = true

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

    override func mouseDown(with event: NSEvent) {
        guard editable else { return }
        toggle()
    }

    func update(checked: Bool, editable: Bool, state: ImportStepModel.RowState) {
        self.editable = editable
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

/// A document view that lays out from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
