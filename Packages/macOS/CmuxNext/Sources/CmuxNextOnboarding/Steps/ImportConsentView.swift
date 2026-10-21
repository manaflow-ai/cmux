import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextIcons

/// The Keychain explainer, shown in place of the profile list right before
/// saved passwords are decrypted: one line on why macOS asks for the
/// computer password, naming the Keychain item it asks about. Begin
/// Importing (the footer button, Return) confirms; Skip Importing (the
/// footer's Skip) leaves with nothing read; the footer's Back returns to the list; Import
/// Without Passwords brings the rest. After a refused confirmation, the
/// passwords can still come from the browser's CSV export.
final class ImportConsentView: NSView {
    private let model: ImportStepModel
    private let line = OnboardingLabel.make(color: Palette.textSecondary, lines: 4)
    private let denied = OnboardingLabel.make(OnboardingStrings.passwordsAuthDenied, font: OnboardingMetrics.captionFont,
                                              color: Palette.textSecondary, lines: 2)
    private var actions: [NSButton] = []
    private let progress = OnboardingProgressBar()
    private let csv: NSButton
    private var shownProfiles: [BrowserSourceProfile]?

    init(model: ImportStepModel) {
        self.model = model
        csv = OnboardingControl.plainButton(OnboardingStrings.importPasswordsCSV, target: nil, action: #selector(importCSV))
        super.init(frame: .zero)
        csv.target = self
        csv.setAccessibilityIdentifier("cmux.onboarding.import.passwordsCSV")
        let lock = NSImageView(image: NSImage.icon(.credentialConsent, size: 18))
        lock.contentTintColor = Palette.textSecondary
        let title = OnboardingLabel.make(OnboardingStrings.unlockTitle, font: .systemFont(ofSize: 15, weight: .semibold), lines: 2)
        let heading = NSStackView(views: [lock, title])
        heading.spacing = 8
        // Pinned to the stack's width below, so the title wraps to its full two-line height.
        heading.alignment = .firstBaseline
        let without = OnboardingControl.plainButton(OnboardingStrings.importWithoutPasswords, target: self, action: #selector(skipPasswords))
        actions = [without]
        let buttons = NSStackView(views: [without, csv])
        buttons.spacing = 16
        denied.isHidden = true
        csv.isHidden = true
        let stack = NSStackView(views: [progress, heading, line, denied, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: denied)
        stack.setCustomSpacing(20, after: progress)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.5),
            line.widthAnchor.constraint(equalTo: stack.widthAnchor),
            denied.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func skipPasswords() { model.skipPasswords() }
    @objc private func importCSV() { model.importPasswordsFromCSV() }

    /// Called from the step's render loop.
    func render() {
        let profiles = model.passwordProfiles
        if profiles != shownProfiles {
            shownProfiles = profiles
            line.stringValue = Self.text(keychainItems: model.passwordKeychainItems, includesFirefox: model.passwordsIncludeFirefox)
        }
        progress.value = model.explainerProgress ?? 0
        // While Touch ID is up the choice is fixed; a cancelled one says nothing was read.
        actions.forEach { $0.isEnabled = !model.authorizing }
        denied.isHidden = !model.authorizationDenied
        csv.isHidden = !model.offersPasswordCSV
    }

    /// The one line: the Keychain items macOS asks about; Firefox alone asks for none.
    static func text(keychainItems: [String], includesFirefox: Bool, locale: Locale = .current) -> String {
        guard !keychainItems.isEmpty else { return OnboardingStrings.passwordsFirefoxOnly }
        let line = OnboardingStrings.unlockLine(quotedList(keychainItems, locale: locale))
        return includesFirefox ? line + " " + OnboardingStrings.passwordsFirefoxPrimary : line
    }

    /// “Microsoft Edge Safe Storage” and “Google Chrome Safe Storage”, in the user's quotation marks and list style.
    static func quotedList(_ items: [String], locale: Locale = .current) -> String {
        let open = locale.quotationBeginDelimiter ?? "“"
        let close = locale.quotationEndDelimiter ?? "”"
        return items.map { open + $0 + close }.formatted(.list(type: .and).locale(locale))
    }
}
