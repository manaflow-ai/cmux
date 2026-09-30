import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// Right side of the import step: what to import, the Import / Cancel
/// button, progress with live counts, then the summary.
final class ImportPanelView: NSView {
    private let model: ImportStepModel
    private var chips: [ImportDataKind: ChipToggle] = [:]
    private let action = OnboardingButton(OnboardingStrings.importButton, style: .primary)
    private let progress = ProgressBar()
    private let status = OnboardingLabel.make(font: Typography.caption, color: Palette.textSecondary, lines: 2)
    private let counts = ImportCountsView()
    private let summary: ImportSummaryView
    private let notes: NSStackView
    private let chipGrid = NSGridView()
    private var loop: RenderLoop?

    init(model: ImportStepModel) {
        self.model = model
        summary = ImportSummaryView(model: model)
        let secrets = OnboardingLabel.make(OnboardingStrings.secretsNote, font: Typography.caption, color: Palette.textTertiary, lines: 3)
        let profiles = OnboardingLabel.make(OnboardingStrings.profilesNote, font: Typography.caption, color: Palette.textTertiary, lines: 3)
        notes = NSStackView(views: [profiles, secrets])
        notes.orientation = .vertical
        notes.alignment = .leading
        notes.spacing = Metrics.space4
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        chipGrid.rowSpacing = Metrics.space3
        chipGrid.columnSpacing = Metrics.space3
        var row: [NSView] = []
        for kind in ImportStepModel.offeredKinds {
            let chip = ChipToggle(title: OnboardingStrings.kind(kind))
            chip.onToggle = { [weak model] in model?.toggle(kind) }
            chips[kind] = chip
            row.append(chip)
            if row.count == 2 { chipGrid.addRow(with: row); row = [] }
        }
        action.onPress = { [weak self] in self?.pressAction() }
        let actionRow = NSStackView(views: [action, FlexibleSpace()])
        let stack = NSStackView(views: [chipGrid, notes, counts, summary, actionRow, progress, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            notes.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            secrets.widthAnchor.constraint(equalTo: notes.widthAnchor),
            profiles.widthAnchor.constraint(equalTo: notes.widthAnchor),
        ])
        profiles.isHidden = model.browserProfilesAvailable
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func pressAction() {
        if model.isImporting { return model.cancel() }
        if phaseIsFinished(model.phase) { return model.reset() }
        model.start()
    }

    private func render() {
        let phase = model.phase
        let editable = model.canEditSelection
        for (kind, chip) in chips {
            chip.isOn = model.kinds.contains(kind)
            chip.isEnabled = editable
        }
        action.title = model.isImporting ? OnboardingStrings.cancel : (phaseIsFinished(phase) ? OnboardingStrings.importAgain : OnboardingStrings.importButton)
        let finished = phaseIsFinished(phase)
        action.style = model.isImporting ? .secondary : (finished ? .plain : .primary)
        action.isEnabled = model.isImporting || finished || model.canStart
        chipGrid.isHidden = finished
        progress.isHidden = !model.isImporting
        counts.isHidden = true
        summary.isHidden = true
        notes.isHidden = phaseIsFinished(phase)
        switch phase {
        case .importing(let step):
            progress.fraction = step?.fraction ?? 0
            status.stringValue = step.map { $0.kind == nil ? OnboardingStrings.saving : OnboardingStrings.importing(sourceName($0.profile)) } ?? ""
            if let step { counts.isHidden = false; counts.show(step.counts) }
        case .finished(let result):
            let failures = result.failures.keys.sorted().map(OnboardingStrings.couldNotRead)
            status.stringValue = failures.joined(separator: " ")
            counts.isHidden = false
            counts.show(result.counts)
            summary.isHidden = false
        case .cancelled:
            status.stringValue = OnboardingStrings.cancelled
        case .failed(let reason):
            status.stringValue = OnboardingStrings.failed(reason)
        default:
            status.stringValue = ""
        }
        status.isHidden = status.stringValue.isEmpty
    }

    private func phaseIsFinished(_ phase: ImportStepModel.Phase) -> Bool {
        if case .finished = phase { return true }
        return false
    }

    private func sourceName(_ profile: BrowserSourceProfile) -> String {
        profile.browser.family == .safari ? profile.browser.displayName : "\(profile.browser.displayName) · \(profile.displayName)"
    }
}

/// A thin determinate bar; the width eases to each new fraction.
final class ProgressBar: ThemedView {
    private let bar = ThemedView()
    private var width: NSLayoutConstraint?
    var fraction: Double = 0 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill = { Palette.selectionFill }
        cornerRadius = 1.5
        bar.fill = { Palette.textPrimary }
        bar.cornerRadius = 1.5
        addSubview(bar)
        heightAnchor.constraint(equalToConstant: 3).isActive = true
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        width = bar.widthAnchor.constraint(equalToConstant: 0)
        width?.isActive = true
    }

    override func layout() {
        super.layout()
        let target = bounds.width * min(max(fraction, 0), 1)
        guard let width, abs(width.constant - target) > 0.5 else { return }
        Motion.animateTimed(.move) { width.animator().constant = target }
    }
}
