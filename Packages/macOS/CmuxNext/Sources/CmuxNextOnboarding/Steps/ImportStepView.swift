import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// Import: one row per detected browser profile (the browser's own icon,
/// the profile's picture and name, a checkbox), then one line of what to
/// bring. Import runs in place: each row shows its progress, then what came
/// over; the line under the list sums it up. With passwords checked,
/// Import first swaps the list for the consent screen (`ImportConsentView`).
final class ImportStepView: NSView {
    private let model: ImportStepModel
    private let list = NSStackView()
    private let kinds = NSStackView()
    private let status = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textTertiary, lines: 2)
    private var rows: [String: ImportProfileRow] = [:]
    private var rowSlots: [ImportProfileRow] = []
    private var kindBoxes: [ImportDataKind: NSButton] = [:]
    private var kindSlots: [NSButton] = []
    private var shownKinds: [ImportDataKind] = []
    private let consent: ImportConsentView
    private var listViews: [NSView] = []
    private var shownProfiles: [BrowserSourceProfile]?
    private var loop: RenderLoop?

    init(model: ImportStepModel) {
        self.model = model
        consent = ImportConsentView(model: model)
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        // Keep the viewport's row geometry mounted while browser detection is
        // running. Detection fills these slots in place instead of replacing
        // the list and moving the controls under the pointer.
        for _ in 0..<4 {
            let row = ImportProfileRow(toggle: nil)
            rowSlots.append(row)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        // Kind choices are also discovered asynchronously (passwords may be
        // added after the first probe). Keep their controls mounted and fill
        // the existing slots when the probe completes.
        for _ in ImportDataKind.allCases {
            let box = OnboardingControl.checkbox("", target: self, action: #selector(kindToggled(_:)))
            box.alphaValue = 0
            kindSlots.append(box)
            kinds.addArrangedSubview(box)
        }
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        SystemScrollers.follow(scroll)
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        kinds.spacing = 20
        let separator = ThemedView()
        separator.fill = { Palette.separator }
        listViews = [scroll, separator, kinds]
        consent.isHidden = true
        let stack = NSStackView(views: [scroll, separator, kinds, consent, status])
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
            consent.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func kindToggled(_ sender: NSButton) { model.toggle(shownKinds[sender.tag]) }
    private func render() {
        let confirming = model.isConfirmingPasswords
        listViews.forEach { $0.isHidden = confirming }
        consent.isHidden = !confirming
        if confirming { consent.render() }
        let profiles = model.profiles
        if profiles != shownProfiles {
            shownProfiles = profiles
            rows = [:]
            let apps = Dictionary(model.sources.map { ($0.browser, $0.appURL) }, uniquingKeysWith: { first, _ in first })
            let blockedBrowsers = Set(model.sources.filter(\.needsFullDiskAccess).map(\.browser))
            while rowSlots.count < profiles.count {
                let row = ImportProfileRow(toggle: nil)
                rowSlots.append(row)
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            for (index, row) in rowSlots.enumerated() {
                guard profiles.indices.contains(index) else {
                    row.clearProfile()
                    continue
                }
                let profile = profiles[index]
                row.configure(profile: profile, appURL: apps[profile.browser] ?? nil,
                              needsFullDiskAccess: blockedBrowsers.contains(profile.browser),
                              onAccess: { [weak model] in model?.openFullDiskAccessSettings() }) { [weak model] in model?.toggle(profile) }
                rows[profile.id] = row
            }
        }
        let editable = model.canEditSelection
        for profile in profiles {
            rows[profile.id]?.update(checked: model.isSelected(profile), editable: editable, state: model.rowState(profile))
        }
        if model.kindChoices != shownKinds {
            shownKinds = model.kindChoices
            kindBoxes = [:]
            for (index, box) in kindSlots.enumerated() {
                guard shownKinds.indices.contains(index) else {
                    box.title = ""
                    box.attributedTitle = NSAttributedString(string: "")
                    box.alphaValue = 0
                    box.isEnabled = false
                    continue
                }
                let kind = shownKinds[index]
                let title = OnboardingStrings.kind(kind)
                box.title = title
                box.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: OnboardingMetrics.bodyFont, .foregroundColor: Palette.textPrimary,
                ])
                box.tag = index
                box.alphaValue = 1
                kindBoxes[kind] = box
            }
        }
        for (kind, box) in kindBoxes {
            box.state = model.kinds.contains(kind) ? .on : .off
            box.isEnabled = editable
        }
        status.stringValue = statusText(profiles)
    }

    private func statusText(_ profiles: [BrowserSourceProfile]) -> String {
        switch model.phase {
        case .idle: return OnboardingStrings.notSearched
        case .detecting: return OnboardingStrings.detecting
        case .importing, .confirmingPasswords: return ""
        case .finished(let summary):
            let counts = ImportCountsText.line(summary.counts)
            var line = counts.isEmpty ? OnboardingStrings.importedNothing : OnboardingStrings.imported(counts)
            // "412 imported, 9 skipped": counts only, never which sites.
            let passwords = OnboardingStrings.passwordsSummary(summary.batches.compactMap(\.passwords))
            if !passwords.isEmpty { line += " " + passwords }
            if summary.batches.contains(where: { $0.passwordError != nil }) { line += " " + OnboardingStrings.passwordsNotRead }
            return summary.failures.isEmpty ? line : line + " " + OnboardingStrings.importSomeFailed
        case .failed(let message): return message
        default:
            return profiles.isEmpty ? OnboardingStrings.noBrowsers : ""
        }
    }
}

/// A document view that lays out from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
