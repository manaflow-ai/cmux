import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// Import: one checkbox per detected browser profile, then one line of
/// what to bring (bookmarks, history, sign-ins). Continue starts it.
final class ImportStepView: NSView {
    private let model: ImportStepModel
    private let list = NSStackView()
    private let kinds = NSStackView()
    private let status = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textTertiary, lines: 2)
    private let access = NSStackView()
    private var profileBoxes: [String: NSButton] = [:]
    private var kindBoxes: [ImportDataKind: NSButton] = [:]
    private var shownProfiles: [BrowserSourceProfile]?
    private var loop: RenderLoop?

    init(model: ImportStepModel) {
        self.model = model
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
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
            scroll.heightAnchor.constraint(equalToConstant: 150),
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

    @objc private func profileToggled(_ sender: NSButton) {
        guard let profile = model.profiles.first(where: { profileBoxes[$0.id] === sender }) else { return }
        model.toggle(profile)
    }

    private func render() {
        let profiles = model.profiles
        if profiles != shownProfiles {
            shownProfiles = profiles
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            profileBoxes = [:]
            for profile in profiles {
                let box = OnboardingControl.checkbox(OnboardingStrings.profileName(profile), target: self, action: #selector(profileToggled(_:)))
                profileBoxes[profile.id] = box
                list.addArrangedSubview(box)
            }
        }
        let editable = model.canEditSelection
        for profile in profiles {
            profileBoxes[profile.id]?.state = model.isSelected(profile) ? .on : .off
            profileBoxes[profile.id]?.isEnabled = editable
        }
        for (kind, box) in kindBoxes {
            box.state = model.kinds.contains(kind) ? .on : .off
            box.isEnabled = editable
        }
        access.isHidden = !model.needsFullDiskAccess
        switch model.phase {
        case .idle, .detecting: status.stringValue = OnboardingStrings.detecting
        case .importing(let progress): status.stringValue = progress.map { OnboardingStrings.importing(OnboardingStrings.profileName($0.profile)) } ?? ""
        default:
            status.stringValue = profiles.isEmpty ? OnboardingStrings.noBrowsers
                : (model.kinds.contains(.cookies) ? OnboardingStrings.keychainNote : "")
        }
    }
}

/// A document view that lays out from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
