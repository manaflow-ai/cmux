import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// The folder grant explainer, shown in place of the profile list after
/// Allow Access… on a browser cmux has no access to: cmux reads no other
/// browser's profiles until the person picks that browser's folder. Continue
/// (the footer button, Return) opens the open panel there; the footer's Back
/// returns to the list.
final class ImportAccessView: NSView {
    private let model: ImportStepModel
    private let title = OnboardingLabel.make(font: .systemFont(ofSize: TypeScale.title, weight: TypeScale.emphasis), lines: 2)
    private let noAccess = OnboardingLabel.make(OnboardingStrings.accessNone, color: Palette.textSecondary, lines: 2)
    private let how = OnboardingLabel.make(color: Palette.textSecondary, lines: 2)
    private let stepContinue = OnboardingLabel.make(OnboardingStrings.accessStepContinue, color: Palette.textSecondary, lines: 1)
    private let stepPick = OnboardingLabel.make(OnboardingStrings.accessStepOpen, color: Palette.textSecondary, lines: 2)
    /// The folder on its own line, ~ for the home directory.
    private let folder = OnboardingLabel.make(font: .monospacedSystemFont(ofSize: TypeScale.body, weight: TypeScale.regular), lines: 2)
    private let progress = OnboardingProgressBar()
    private let refused = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary, lines: 2)
    private var shown: ImportBrowser?

    init(model: ImportStepModel) {
        self.model = model
        super.init(frame: .zero)
        refused.isHidden = true
        folder.setAccessibilityIdentifier("cmux.onboarding.import.access.folder")
        let steps = NSStackView(views: [stepContinue, stepPick, folder])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 4
        steps.setCustomSpacing(8, after: stepPick)
        let stack = NSStackView(views: [progress, title, noAccess, how, steps, refused])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(20, after: progress)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            steps.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.5),
        ]
        for label in [title, noAccess, how, refused, stepPick, folder] { constraints.append(label.widthAnchor.constraint(equalTo: stack.widthAnchor)) }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Called from the step's render loop.
    func render() {
        guard let browser = model.explainingAccess else { return }
        let path = Self.displayPath(model.folderPath(browser))
        if browser != shown {
            shown = browser
            title.stringValue = OnboardingStrings.accessTitle(browser.displayName)
            how.stringValue = OnboardingStrings.accessHow(browser.displayName)
            folder.stringValue = path
        }
        progress.value = model.explainerProgress ?? 0
        refused.stringValue = OnboardingStrings.accessNotGranted(path)
        refused.isHidden = !model.accessNotGranted
    }

    /// `~/Library/Application Support/Google/Chrome` for a folder in the home directory.
    static func displayPath(_ url: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        guard let url else { return "" }
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return (path as NSString).abbreviatingWithTildeInPath }
        return "~" + path.dropFirst(homePath.count)
    }
}
