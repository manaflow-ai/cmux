import AppKit
import CmuxNextDesign

/// The phone tab's setup screen, shown in place of the phone while this Mac
/// cannot run an iPhone simulator yet. It says in plain words what is
/// missing and why, lists the steps with the done ones checked, and offers
/// one button for the next step. It draws a ``PhoneSetupViewState``; the tab
/// handles the buttons through ``onAction``.
@MainActor
final class PhoneSetupView: NSView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let rows = NSStackView()
    private let progressBar = PhoneProgressBar()
    private let spinner = StatusIndicatorView.spinner()
    private let progressLabel = NSTextField(labelWithString: "")
    private let failureLabel = NSTextField(wrappingLabelWithString: "")
    private let primary = ThemedBezelButton()
    private let secondary = ThemedBezelButton()
    private let checkAgain = NSButton()
    private let autoCheck = NSTextField(wrappingLabelWithString: PhoneStrings.setupAutoCheck)
    private let androidNote = NSTextField(wrappingLabelWithString: PhoneStrings.setupAndroidNote)
    private let androidButton = NSButton()
    private var shown: PhoneSetupViewState?

    /// Runs a button's action.
    var onAction: (@MainActor (PhoneSetupAction) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Draws `state`; does nothing when it is what is already shown.
    func show(_ state: PhoneSetupViewState) {
        guard state != shown else { return }
        shown = state
        titleLabel.stringValue = state.title
        bodyLabel.stringValue = state.body
        bodyLabel.isHidden = state.body.isEmpty
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in state.rows { rows.addArrangedSubview(Self.rowView(row)) }
        progressLabel.stringValue = state.progressText ?? ""
        progressLabel.isHidden = state.progressText == nil
        progressBar.isHidden = state.progress == nil
        progressBar.fraction = state.progress ?? 0
        let waiting = state.progressText != nil && state.progress == nil
        spinner.isHidden = !waiting
        spinner.spin(waiting)
        failureLabel.stringValue = state.failure ?? ""
        failureLabel.toolTip = state.failureDetail
        failureLabel.isHidden = state.failure == nil
        apply(state.primary, to: primary)
        apply(state.secondary, to: secondary)
    }

    private func apply(_ button: PhoneSetupViewState.Button?, to view: ThemedBezelButton) {
        view.isHidden = button == nil
        view.title = button?.title ?? ""
        if view === primary { view.keyHint = button?.action == .cancelDownload ? .escape : .return }
        view.setAccessibilityLabel(button?.title)
    }

    private static func rowView(_ row: PhoneSetupViewState.Row) -> NSView {
        let symbol = row.done ? "checkmark.circle.fill" : row.current ? "arrow.right.circle.fill" : "circle"
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = row.done ? .systemGreen : row.current ? .controlAccentColor : .tertiaryLabelColor
        let label = NSTextField(labelWithString: row.title)
        label.font = .systemFont(ofSize: TypeScale.body, weight: row.current ? TypeScale.emphasis : TypeScale.regular)
        label.textColor = row.current ? .labelColor : .secondaryLabelColor
        let stack = NSStackView(views: [image, label])
        stack.spacing = 8
        stack.setAccessibilityElement(true)
        stack.setAccessibilityLabel(row.title)
        stack.setAccessibilityValue(row.done ? "done" : row.current ? "next" : "")
        return stack
    }

    private func build() {
        icon.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: TypeScale.regular)
        icon.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: TypeScale.title, weight: TypeScale.emphasis)
        titleLabel.alignment = .center
        bodyLabel.font = .systemFont(ofSize: TypeScale.body, weight: TypeScale.regular)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.alignment = .center
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        progressLabel.font = .monospacedDigitSystemFont(ofSize: TypeScale.detail, weight: TypeScale.regular)
        progressLabel.textColor = .secondaryLabelColor
        failureLabel.font = .systemFont(ofSize: TypeScale.detail, weight: TypeScale.regular)
        failureLabel.textColor = .systemRed
        failureLabel.alignment = .center
        for (button, action) in [(primary, #selector(primaryClicked)), (secondary, #selector(secondaryClicked))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        checkAgain.title = PhoneStrings.setupCheckAgain
        checkAgain.isBordered = false
        checkAgain.contentTintColor = .linkColor
        checkAgain.target = self
        checkAgain.action = #selector(checkAgainClicked)
        autoCheck.font = .systemFont(ofSize: TypeScale.caption, weight: TypeScale.regular)
        autoCheck.textColor = .tertiaryLabelColor
        autoCheck.alignment = .center
        androidNote.font = .systemFont(ofSize: TypeScale.caption, weight: TypeScale.regular)
        androidNote.textColor = .tertiaryLabelColor
        androidNote.alignment = .center
        androidButton.title = PhoneStrings.setupGetAndroidStudio
        androidButton.isBordered = false
        androidButton.contentTintColor = .linkColor
        androidButton.font = .systemFont(ofSize: TypeScale.caption, weight: TypeScale.regular)
        androidButton.target = self
        androidButton.action = #selector(androidClicked)

        let buttons = NSStackView(views: [secondary, primary])
        buttons.spacing = 8
        let column = NSStackView(views: [icon, titleLabel, bodyLabel, rows, progressBar, spinner, progressLabel, failureLabel, buttons,
                                         checkAgain, autoCheck, androidNote, androidButton])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 12
        column.setCustomSpacing(4, after: checkAgain)
        column.setCustomSpacing(24, after: autoCheck)
        column.setCustomSpacing(2, after: androidNote)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            column.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            column.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
            progressBar.widthAnchor.constraint(equalTo: column.widthAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 6),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            bodyLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            failureLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            autoCheck.widthAnchor.constraint(equalTo: column.widthAnchor),
            androidNote.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @objc private func primaryClicked() { if let action = shown?.primary?.action { onAction?(action) } }
    @objc private func secondaryClicked() { if let action = shown?.secondary?.action { onAction?(action) } }
    @objc private func checkAgainClicked() { onAction?(.checkAgain) }
    @objc private func androidClicked() { onAction?(.getAndroidStudio) }
}
