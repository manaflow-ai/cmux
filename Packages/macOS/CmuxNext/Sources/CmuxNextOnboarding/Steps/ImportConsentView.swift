import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// The password consent screen, shown in place of the profile list after
/// Import when passwords are checked: which profiles (each can be
/// unchecked), the Keychain item macOS asks about next and why, and where
/// the passwords go. Nothing is read until Import (the footer button);
/// Import Without Passwords brings the rest, Back returns to the list.
final class ImportConsentView: NSView {
    private let model: ImportStepModel
    private let list = NSStackView()
    private let keychain = OnboardingLabel.make(color: Palette.textSecondary, lines: 4)
    private var rows: [String: ImportProfileRow] = [:]
    private var shownProfiles: [BrowserSourceProfile]?

    init(model: ImportStepModel) {
        self.model = model
        super.init(frame: .zero)
        let lock = NSImageView(image: NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil) ?? NSImage())
        lock.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        lock.contentTintColor = Palette.textSecondary
        let title = OnboardingLabel.make(OnboardingStrings.passwordsTitle, font: .systemFont(ofSize: 15, weight: .semibold), lines: 2)
        let heading = NSStackView(views: [lock, title])
        heading.spacing = 8
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        let store = OnboardingLabel.make(OnboardingStrings.passwordsStore, font: OnboardingMetrics.captionFont, color: Palette.textTertiary, lines: 3)
        let back = OnboardingControl.plainButton(OnboardingStrings.back, target: self, action: #selector(goBack))
        let without = OnboardingControl.plainButton(OnboardingStrings.importWithoutPasswords, target: self, action: #selector(skipPasswords))
        let actions = NSStackView(views: [back, without])
        actions.spacing = 16
        let stack = NSStackView(views: [heading, keychain, list, store, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: list)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keychain.widthAnchor.constraint(equalTo: stack.widthAnchor),
            store.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func goBack() { model.backFromConsent() }
    @objc private func skipPasswords() { model.skipPasswords() }

    /// Called from the step's render loop.
    func render() {
        let profiles = model.passwordProfiles
        if profiles != shownProfiles {
            shownProfiles = profiles
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            rows = [:]
            let apps = Dictionary(model.sources.map { ($0.browser, $0.appURL) }, uniquingKeysWith: { first, _ in first })
            for profile in profiles {
                let row = ImportProfileRow(profile: profile, appURL: apps[profile.browser] ?? nil) { [weak model] in model?.toggleConsent(profile) }
                rows[profile.id] = row
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            keychain.stringValue = OnboardingStrings.passwordsKeychain(Self.quotedList(model.passwordKeychainItems))
        }
        for profile in profiles {
            rows[profile.id]?.update(checked: model.passwordConsent.contains(profile.id), editable: true, state: .idle)
        }
    }

    /// “Microsoft Edge Safe Storage” and “Google Chrome Safe Storage”, in the user's quotation marks and list style.
    static func quotedList(_ items: [String], locale: Locale = .current) -> String {
        let open = locale.quotationBeginDelimiter ?? "“"
        let close = locale.quotationEndDelimiter ?? "”"
        return items.map { open + $0 + close }.formatted(.list(type: .and).locale(locale))
    }
}
