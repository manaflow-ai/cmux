#if os(iOS)
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileSupport
import CmuxMobileWorkspace
import Foundation
import Observation
import StackAuth
import UIKit

/// Native sign-in surface for OAuth and email-code authentication.
@MainActor
final class MobileSignInViewController: UIViewController, UITextFieldDelegate {
    private let auth: AuthCoordinator
    private let analytics: any AnalyticsEmitting
    private let errorPresentation = SignInErrorPresentation()

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let brandStack = UIStackView()
    private let restoreStatusLabel = UILabel()
    private let oauthStack = UIStackView()
    private let emailStack = UIStackView()
    private let codeStack = UIStackView()
    private let emailField = UITextField()
    private let codeField = UITextField()
    private let errorLabel = UILabel()
    private let sendCodeButton = UIButton(type: .system)
    private let verifyCodeButton = UIButton(type: .system)
    private let differentEmailButton = UIButton(type: .system)
    private var oauthButtons: [OAuthSignInProvider: UIButton] = [:]
    private var signingInProviders: Set<OAuthSignInProvider> = []
    private var authenticationTasks: [UUID: Task<Void, Never>] = [:]
    private var observationGeneration: UInt64 = 0
    private var showsCodeEntry = false

    init(auth: AuthCoordinator, analytics: any AnalyticsEmitting) {
        self.auth = auth
        self.analytics = analytics
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("mobile.signIn.title", defaultValue: "cmux")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for task in authenticationTasks.values {
            task.cancel()
        }
    }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .systemBackground
        view = root

        configureScrollView(in: root)
        configureContent()
        configureKeyboardDismissal(in: root)
        render()
        observeAuthentication()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !showsCodeEntry, !auth.isRestoringSession {
            emailField.becomeFirstResponder()
        }
    }

    private func configureScrollView(in root: UIView) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        root.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        let width = contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        width.priority = .required
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(greaterThanOrEqualTo: scrollView.contentLayoutGuide.topAnchor, constant: 32),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            contentStack.centerYAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerYAnchor).withPriority(.defaultLow),
            width,
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
            contentStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
        ])
    }

    private func configureContent() {
        brandStack.axis = .horizontal
        brandStack.alignment = .center
        brandStack.distribution = .equalCentering
        brandStack.spacing = 10

        let logo = UIImageView(image: UIImage(named: "CmuxLogo", in: .module, compatibleWith: nil))
        logo.contentMode = .scaleAspectFit
        logo.isAccessibilityElement = false
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 28),
            logo.heightAnchor.constraint(equalToConstant: 28),
        ])
        let titleLabel = UILabel()
        titleLabel.text = L10n.string("mobile.signIn.title", defaultValue: "cmux")
        titleLabel.font = .preferredFont(forTextStyle: .title2).withWeight(.semibold)
        let brandContent = UIStackView(arrangedSubviews: [logo, titleLabel])
        brandContent.axis = .horizontal
        brandContent.alignment = .center
        brandContent.spacing = 10
        brandStack.addArrangedSubview(UIView())
        brandStack.addArrangedSubview(brandContent)
        brandStack.addArrangedSubview(UIView())
        contentStack.addArrangedSubview(brandStack)

        restoreStatusLabel.font = .preferredFont(forTextStyle: .footnote)
        restoreStatusLabel.textColor = .secondaryLabel
        restoreStatusLabel.textAlignment = .center
        restoreStatusLabel.numberOfLines = 0
        contentStack.addArrangedSubview(restoreStatusLabel)

        oauthStack.axis = .vertical
        oauthStack.spacing = 12
        for provider in OAuthSignInProvider.allCases {
            let button = configuredOAuthButton(for: provider)
            oauthButtons[provider] = button
            oauthStack.addArrangedSubview(button)
        }
        contentStack.addArrangedSubview(oauthStack)
        contentStack.addArrangedSubview(makeDivider())

        emailStack.axis = .vertical
        emailStack.spacing = 12
        configureTextField(
            emailField,
            placeholder: L10n.string("mobile.signIn.emailPlaceholder", defaultValue: "Email address"),
            identifier: "Email"
        )
        emailField.keyboardType = .emailAddress
        emailField.textContentType = .emailAddress
        emailField.autocapitalizationType = .none
        emailField.autocorrectionType = .no
        emailField.returnKeyType = .go
        emailField.addTarget(self, action: #selector(emailChanged), for: .editingChanged)
        emailStack.addArrangedSubview(emailField)

        sendCodeButton.configuration = primaryButtonConfiguration(
            title: L10n.string("mobile.signIn.emailCode", defaultValue: "Email me a code")
        )
        sendCodeButton.accessibilityIdentifier = "signin.emailCode"
        sendCodeButton.addAction(UIAction { [weak self] _ in self?.sendCode() }, for: .touchUpInside)
        emailStack.addArrangedSubview(sendCodeButton)
        contentStack.addArrangedSubview(emailStack)

        codeStack.axis = .vertical
        codeStack.spacing = 12
        let checkEmailLabel = UILabel()
        checkEmailLabel.text = L10n.string("mobile.signIn.checkEmail", defaultValue: "Check your email")
        checkEmailLabel.font = .preferredFont(forTextStyle: .headline)
        checkEmailLabel.textAlignment = .center
        codeStack.addArrangedSubview(checkEmailLabel)

        configureTextField(
            codeField,
            placeholder: L10n.string("mobile.signIn.codePlaceholder", defaultValue: "ABC123"),
            identifier: "signin.code"
        )
        codeField.font = .monospacedSystemFont(ofSize: 32, weight: .semibold)
        codeField.textAlignment = .center
        codeField.textContentType = .oneTimeCode
        codeField.autocapitalizationType = .allCharacters
        codeField.autocorrectionType = .no
        codeField.returnKeyType = .go
        codeField.addTarget(self, action: #selector(codeChanged), for: .editingChanged)
        codeStack.addArrangedSubview(codeField)

        verifyCodeButton.configuration = primaryButtonConfiguration(
            title: L10n.string("mobile.signIn.verifyCode", defaultValue: "Verify code")
        )
        verifyCodeButton.accessibilityIdentifier = "signin.verifyCode"
        verifyCodeButton.addAction(UIAction { [weak self] _ in self?.verifyCode() }, for: .touchUpInside)
        codeStack.addArrangedSubview(verifyCodeButton)

        differentEmailButton.configuration = .plain()
        differentEmailButton.configuration?.title = L10n.string(
            "mobile.signIn.useDifferentEmail",
            defaultValue: "Use a different email"
        )
        differentEmailButton.addAction(UIAction { [weak self] _ in self?.showEmailEntry() }, for: .touchUpInside)
        codeStack.addArrangedSubview(differentEmailButton)
        contentStack.addArrangedSubview(codeStack)

        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.accessibilityIdentifier = "signin.error"
        errorLabel.isAccessibilityElement = true
        contentStack.addArrangedSubview(errorLabel)
    }

    private func configuredOAuthButton(for provider: OAuthSignInProvider) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.bordered()
        configuration.cornerStyle = .capsule
        configuration.title = provider.nativeTitle
        configuration.image = provider.nativeImage
        configuration.imagePadding = 7
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18)
        button.configuration = configuration
        button.accessibilityIdentifier = provider.accessibilityIdentifier
        button.addAction(UIAction { [weak self] _ in self?.signIn(with: provider) }, for: .touchUpInside)
        return button
    }

    private func makeDivider() -> UIView {
        let label = UILabel()
        label.text = L10n.string("mobile.signIn.emailDivider", defaultValue: "or continue with email")
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }

    private func configureTextField(
        _ field: UITextField,
        placeholder: String,
        identifier: String
    ) {
        field.delegate = self
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.clearButtonMode = .whileEditing
        field.accessibilityIdentifier = identifier
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
    }

    private func primaryButtonConfiguration(title: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.title = title
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18)
        return configuration
    }

    private func configureKeyboardDismissal(in root: UIView) {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        gesture.cancelsTouchesInView = false
        root.addGestureRecognizer(gesture)
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func emailChanged() {
        render()
    }

    @objc private func codeChanged() {
        let rawCode = codeField.text ?? ""
        switch SignInCodeInputPolicy.action(for: rawCode) {
        case .assign(let normalizedCode):
            if normalizedCode != rawCode {
                codeField.text = normalizedCode
            }
        case .verify:
            verifyCode()
        case .none:
            break
        }
        render()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === emailField {
            sendCode()
        } else if textField === codeField {
            verifyCode()
        }
        return false
    }

    private func observeAuthentication() {
        observationGeneration &+= 1
        let generation = observationGeneration
        withObservationTracking {
            _ = auth.isLoading
            _ = auth.isRestoringSession
            _ = auth.isAuthenticated
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, observationGeneration == generation else { return }
                render()
                observeAuthentication()
            }
        }
    }

    private func render() {
        let busy = auth.isLoading || auth.isRestoringSession || !signingInProviders.isEmpty
        emailStack.isHidden = showsCodeEntry
        oauthStack.isHidden = showsCodeEntry
        codeStack.isHidden = !showsCodeEntry
        restoreStatusLabel.isHidden = !auth.isRestoringSession
        restoreStatusLabel.text = auth.isRestoringSession
            ? L10n.string("mobile.signIn.restoringSession", defaultValue: "Restoring your session…")
            : nil
        sendCodeButton.isEnabled = !busy
            && !(emailField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        verifyCodeButton.isEnabled = !busy && (codeField.text ?? "").count == 6
        emailField.isEnabled = !busy
        codeField.isEnabled = !busy
        differentEmailButton.isEnabled = !busy
        for (provider, button) in oauthButtons {
            button.isEnabled = !busy
            button.configuration?.showsActivityIndicator = signingInProviders.contains(provider)
            button.configuration?.title = signingInProviders.contains(provider) ? nil : provider.nativeTitle
        }
        contentStack.alpha = busy ? 0.65 : 1
        errorLabel.isHidden = errorLabel.text?.isEmpty != false
    }

    private func showEmailEntry() {
        showsCodeEntry = false
        codeField.text = ""
        setError(nil)
        render()
        emailField.becomeFirstResponder()
    }

    private func sendCode() {
        guard sendCodeButton.isEnabled else { return }
        setError(nil)
        let email = (emailField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        analytics.capture("ios_sign_in_started", ["method": .string("email_code")])
        runAuthenticationTask { [weak self] in
            guard let self else { return }
            do {
                try await auth.sendCode(to: email)
                guard !auth.isAuthenticated else { return }
                showsCodeEntry = true
                render()
                codeField.becomeFirstResponder()
            } catch {
                handleSignInError(error, method: "email_code")
            }
        }
    }

    private func verifyCode() {
        guard verifyCodeButton.isEnabled else { return }
        setError(nil)
        let code = codeField.text ?? ""
        runAuthenticationTask { [weak self] in
            guard let self else { return }
            do {
                try await auth.verifyCode(code)
            } catch {
                codeField.text = ""
                handleSignInError(error, method: "email_code")
            }
        }
    }

    private func signIn(with provider: OAuthSignInProvider) {
        guard !signingInProviders.contains(provider) else { return }
        setError(nil)
        signingInProviders.insert(provider)
        render()
        analytics.capture("ios_sign_in_started", ["method": .string(provider.analyticsMethod)])
        runAuthenticationTask { [weak self] in
            guard let self else { return }
            defer {
                signingInProviders.remove(provider)
                render()
            }
            do {
                try await provider.signIn(using: auth)
            } catch {
                handleSignInError(error, method: provider.analyticsMethod)
            }
        }
    }

    private func runAuthenticationTask(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        let id = UUID()
        authenticationTasks[id] = Task { [weak self] in
            await operation()
            self?.authenticationTasks[id] = nil
            self?.render()
        }
        render()
    }

    private func handleSignInError(_ error: Error, method: String) {
        if case AuthError.cancelled = error {
            analytics.capture("ios_sign_in_cancelled", ["method": .string(method)])
            return
        }
        if let stackError = error as? StackAuthErrorProtocol,
           stackError.code == "oauth_cancelled" {
            analytics.capture("ios_sign_in_cancelled", ["method": .string(method)])
            return
        }
        setError(errorPresentation.message(for: error))
        analytics.capture("ios_sign_in_failed", [
            "method": .string(method),
            "failure_reason": .string(errorPresentation.failureReason(for: error)),
        ])
    }

    private func setError(_ message: String?) {
        errorLabel.text = message
        render()
    }
}

private extension OAuthSignInProvider {
    var nativeTitle: String {
        switch self {
        case .apple:
            L10n.string("mobile.signIn.apple", defaultValue: "Sign in with Apple")
        case .google:
            L10n.string("mobile.signIn.google", defaultValue: "Sign in with Google")
        case .github:
            L10n.string("mobile.signIn.github", defaultValue: "Sign in with GitHub")
        }
    }

    var nativeImage: UIImage? {
        switch self {
        case .apple:
            UIImage(systemName: "apple.logo")
        case .google:
            UIImage(named: "GoogleLogo", in: .module, compatibleWith: nil)
        case .github:
            UIImage(named: "GitHubLogo", in: .module, compatibleWith: nil)?.withRenderingMode(.alwaysTemplate)
        }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let traits = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: traits, size: pointSize)
    }
}
#endif
