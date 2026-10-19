import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// The folder grant explainer, shown in place of the profile list after
/// Allow Access… on a browser cmux has no access to: cmux reads no other
/// browser's profiles until the person picks that browser's folder. Continue
/// (the footer button) opens the open panel there; Cancel returns to the list.
final class ImportAccessView: NSView {
    private let model: ImportStepModel
    private let title = OnboardingLabel.make(font: .systemFont(ofSize: TypeScale.title, weight: TypeScale.emphasis), lines: 2)
    private let noAccess = OnboardingLabel.make(OnboardingStrings.accessNone, color: Palette.textSecondary, lines: 2)
    private let how = OnboardingLabel.make(color: Palette.textSecondary, lines: 2)
    private let stepContinue = OnboardingLabel.make(OnboardingStrings.accessStepContinue, color: Palette.textSecondary, lines: 1)
    private let stepPick = OnboardingLabel.make(color: Palette.textSecondary, lines: 3)
    private let refused = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary, lines: 2)
    private var cancelButton: NSButton?
    private var shown: ImportBrowser?

    init(model: ImportStepModel) {
        self.model = model
        super.init(frame: .zero)
        let cancel = OnboardingControl.plainButton(OnboardingStrings.cancel, target: self, action: #selector(cancelPressed))
        cancel.setAccessibilityIdentifier("cmux.onboarding.import.access.cancel")
        cancelButton = cancel
        refused.isHidden = true
        let steps = NSStackView(views: [stepContinue, stepPick])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 4
        let stack = NSStackView(views: [title, noAccess, how, steps, refused, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            steps.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ]
        for label in [title, noAccess, how, refused, stepPick] { constraints.append(label.widthAnchor.constraint(equalTo: stack.widthAnchor)) }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func cancelPressed() { model.cancelAccess() }

    /// Called from the step's render loop.
    func render() {
        guard let browser = model.explainingAccess else { return }
        let path = Self.displayPath(model.folderPath(browser))
        if browser != shown {
            shown = browser
            title.stringValue = OnboardingStrings.accessTitle(browser.displayName)
            how.stringValue = OnboardingStrings.accessHow(browser.displayName)
            stepPick.stringValue = OnboardingStrings.accessStepPick(path)
        }
        refused.stringValue = OnboardingStrings.accessNotGranted(path)
        refused.isHidden = !model.accessNotGranted
        cancelButton?.isEnabled = !model.requestingAccess
    }

    /// `~/Library/Application Support/Google/Chrome` for a folder in the home directory.
    static func displayPath(_ url: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        guard let url else { return "" }
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }
}
