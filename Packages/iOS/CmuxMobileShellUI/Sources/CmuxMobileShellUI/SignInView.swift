import CMUXMobileCore
import Foundation
import CmuxAuthRuntime
import CmuxMobileSupport
import CmuxMobileWorkspace
import StackAuth
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SignInView: View {
    private enum EmailEntryMode: Equatable {
        case methods
        case emailVerification
        case code
    }

    private let usesStandaloneChrome: Bool
    @Environment(AuthCoordinator.self) private var authManager
    @Environment(\.analytics) private var analytics
    @Environment(\.mobileDiagnosticLog) private var diagnosticLog
    @State private var email = ""
    @State private var code = ""
    @State private var emailEntryMode = EmailEntryMode.methods
    @State private var error: String?
    @State private var signingInProviders: Set<OAuthSignInProvider> = []
    @State private var isRequestingEmailVerification = false
    @State private var isRequestingBillingRecovery = false
    @State private var billingRecoveryMessage: String?
    @State private var shouldShowBillingRecovery = false
    @State private var shouldAutofocusCode = false
    @State private var shouldAutofocusEmail = false
    private let errorPresentation = SignInErrorPresentation()
    private let emailCodeFailurePolicy = SignInEmailCodeFailurePolicy()
    @FocusState private var isEmailFocused: Bool
    @FocusState private var isCodeFocused: Bool

    init(usesStandaloneChrome: Bool = true) {
        self.usesStandaloneChrome = usesStandaloneChrome
    }

    @ViewBuilder
    var body: some View {
        if usesStandaloneChrome {
            NavigationStack {
                ZStack {
                    GameOfLifeHeader()
                        .ignoresSafeArea()

                    keyboardDismissSurface
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        signInEntrySwitcher
                    }
                }
                .mobileInlineNavigationTitle()
            }
        } else {
            ScrollView {
                signInEntrySwitcher
                    .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(keyboardDismissSurface)
        }
    }

    private var keyboardDismissSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                UIApplication.shared.dismissMobileKeyboard()
            }
    }

    @ViewBuilder
    private var signInEntrySwitcher: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                signInEntryContent
            }
        } else {
            signInEntryContent
        }
        #else
        signInEntryContent
        #endif
    }

    @ViewBuilder
    private var signInEntryContent: some View {
        switch emailEntryMode {
        case .code:
            codeEntryView
        case .emailVerification:
            emailVerificationView
        case .methods:
            emailEntryView
        }
    }

    private var emailEntryView: some View {
        authCard {
            VStack(spacing: 20) {
                brandHeader
                SignInAuthRestoreStatusView()

                VStack(spacing: 12) {
                    ForEach(OAuthSignInProvider.allCases, id: \.self) { provider in
                        oauthButton(for: provider)
                    }
                }

                DividerLabel(text: L10n.string("mobile.signIn.emailDivider", defaultValue: "or continue with email"))

                VStack(spacing: 12) {
                    GlassInputPill(height: 50, alignment: .leading) {
                        TextField(L10n.string("mobile.signIn.emailPlaceholder", defaultValue: "Email address"), text: $email)
                            .textFieldStyle(.plain)
                            .mobileEmailTextInput()
                            .focused($isEmailFocused)
                            .accessibilityIdentifier("Email")
                    } onTap: {
                        isEmailFocused = true
                    }

                    Button {
                        let autofocusCodeOnSuccess = isEmailFocused
                        Task {
                            await sendCode(autofocusCodeOnSuccess: autofocusCodeOnSuccess)
                        }
                    } label: {
                        Text(L10n.string("mobile.signIn.emailCode", defaultValue: "Email me a code"))
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .contentShape(.capsule)
                    }
                    .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAuthInProgress)
                    .mobileGlassProminentButton()
                    .accessibilityIdentifier("signin.emailCode")

                }

                if let error {
                    errorText(error)
                }
            }
        }
        .opacity(isAuthInProgress ? 0.6 : 1.0)
        .onAppear {
            guard shouldAutofocusEmail else { return }
            isEmailFocused = true
            shouldAutofocusEmail = false
        }
    }

    private var emailVerificationView: some View {
        authCard {
            VStack(spacing: 18) {
                brandHeader
                SignInAuthRestoreStatusView()

                VStack(spacing: 6) {
                    Text(L10n.string("mobile.signIn.verificationTitle", defaultValue: "Verify your email"))
                        .font(.headline)
                    Text(
                        String(
                            format: L10n.string(
                                "mobile.signIn.verificationBodyFormat",
                                defaultValue: "We sent a verification link to %@. Open it, then return here."
                            ),
                            normalizedEmail
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let error {
                    errorText(error)
                }

                Button {
                    Task {
                        await sendCode(
                            autofocusCodeOnSuccess: false,
                            requestVerificationOnUnverifiedEmail: false
                        )
                    }
                } label: {
                    Text(L10n.string("mobile.signIn.verificationContinue", defaultValue: "I verified my email"))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .contentShape(.capsule)
                        .mobileButtonLoading(authManager.isLoading, tint: .primary)
                }
                .disabled(isAuthInProgress)
                .mobileGlassProminentButton()
                .accessibilityIdentifier("signin.emailVerificationContinue")

                SignInBillingRecoveryActions(
                    isVisible: shouldShowBillingRecovery,
                    isAuthInProgress: isAuthInProgress,
                    isRequestingEmailVerification: isRequestingEmailVerification,
                    isRequestingBillingRecovery: $isRequestingBillingRecovery,
                    billingRecoveryMessage: $billingRecoveryMessage,
                    requestEmailVerification: {
                        await requestEmailVerification()
                    },
                    requestBillingRecovery: {
                        await requestBillingRecovery()
                    }
                )

                Button {
                    returnToSignInMethods()
                } label: {
                    Text(L10n.string("mobile.signIn.useDifferentEmail", defaultValue: "Use a different email"))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .disabled(isAuthInProgress)
                .accessibilityIdentifier("signin.useDifferentEmail")
            }
        }
        .opacity(isAuthInProgress ? 0.6 : 1.0)
        .accessibilityIdentifier("signin.emailVerification")
    }

    private var codeEntryView: some View {
        authCard {
            VStack(spacing: 18) {
                brandHeader
                SignInAuthRestoreStatusView()

                VStack(spacing: 6) {
                    Text(L10n.string("mobile.signIn.checkEmail", defaultValue: "Check your email"))
                        .font(.headline)
                    Text(String(format: L10n.string("mobile.signIn.sentCodeFormat", defaultValue: "We sent a code to %@"), email))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                GlassInputPill(height: 60, alignment: .center) {
                    TextField(L10n.string("mobile.signIn.codePlaceholder", defaultValue: "ABC123"), text: $code)
                        .textFieldStyle(.plain)
                        .mobileOneTimeCodeInput()
                        .multilineTextAlignment(.center)
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .focused($isCodeFocused)
                        .onChange(of: code) { _, newValue in
                            switch SignInCodeInputPolicy.action(for: newValue) {
                            case let .assign(normalizedCode):
                                code = normalizedCode
                            case .verify:
                                Task {
                                    await verifyCode()
                                }
                            case .none:
                                break
                            }
                        }
                        .accessibilityIdentifier("signin.code")
                } onTap: {
                    isCodeFocused = true
                }
                .onAppear {
                    guard shouldAutofocusCode else { return }
                    isCodeFocused = true
                    shouldAutofocusCode = false
                }

                if let error {
                    errorText(error)
                }

                Button {
                    Task {
                        await verifyCode()
                    }
                } label: {
                    Text(L10n.string("mobile.signIn.verifyCode", defaultValue: "Verify code"))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .contentShape(.capsule)
                        .mobileButtonLoading(authManager.isLoading, tint: .primary)
                }
                .disabled(code.count != 6 || isAuthInProgress)
                .mobileGlassProminentButton()
                .accessibilityIdentifier("signin.verifyCode")
                .accessibilityLabel(L10n.string("mobile.signIn.verifyCode", defaultValue: "Verify code"))

                Button {
                    let autofocusEmailOnReturn = isCodeFocused
                    withAnimation(.snappy(duration: 0.18)) {
                        shouldAutofocusEmail = autofocusEmailOnReturn
                        emailEntryMode = .methods
                        code = ""
                        error = nil
                    }
                } label: {
                    Text(L10n.string("mobile.signIn.useDifferentEmail", defaultValue: "Use a different email"))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    // While this is true the card dims (opacity 0.6) and inputs disable. There
    // is intentionally no in-app "cancel sign-in" affordance: during the only
    // long phase (the Apple/Google/GitHub system sheet, generous on purpose for
    // provider credentials + 2FA) the system sheet sits above this view and carries its own
    // Cancel, and every coordinator phase is raced against a deadline
    // (AuthTimeouts), so a wedged flow always ends in a localized, retryable
    // AuthError and re-enables the card for retry. Do not reintroduce a manual
    // cancel button here; it was occluded during the system sheet anyway.
    private var isInteractiveAuthInProgress: Bool {
        authManager.isLoading ||
            isRequestingEmailVerification ||
            isRequestingBillingRecovery ||
            !signingInProviders.isEmpty
    }

    private var isAuthInProgress: Bool {
        isInteractiveAuthInProgress || authManager.isRestoringSession
    }

    private func oauthButton(for provider: OAuthSignInProvider) -> some View {
        Button {
            Task {
                await signIn(with: provider)
            }
        } label: {
            provider.label(isLoading: signingInProviders.contains(provider))
                .frame(maxWidth: .infinity)
                .contentShape(.capsule)
        }
        .disabled(isAuthInProgress)
        .mobileGlassButton()
        .accessibilityIdentifier(provider.accessibilityIdentifier)
    }

    private func sendCode(
        autofocusCodeOnSuccess: Bool,
        requestVerificationOnUnverifiedEmail: Bool = true
    ) async {
        error = nil
        diagnosticLog?.recordAppEvent(.authSignInStarted)
        analytics.capture("ios_sign_in_started", ["method": .string("email_code")])
        do {
            try await authManager.sendCode(to: email)
            diagnosticLog?.recordAppEvent(.authCodeRequested)
            guard !authManager.isAuthenticated else {
                diagnosticLog?.recordAppEvent(.authSignInSucceeded)
                return
            }
            shouldAutofocusCode = autofocusCodeOnSuccess
            withAnimation(.snappy(duration: 0.18)) {
                emailEntryMode = .code
            }
        } catch {
            if case AuthError.cancelled = error {
                diagnosticLog?.recordAppEvent(.authSignInCancelled)
                analytics.capture("ios_sign_in_cancelled", ["method": .string("email_code")])
                return
            }
            shouldAutofocusCode = false
            diagnosticLog?.recordAppEvent(
                .authCodeRequestFailed,
                failure: DiagnosticFailureKind.classify(error)
            )
            if emailCodeFailurePolicy.action(for: error) == .requestEmailVerification {
                shouldShowBillingRecovery = true
                if requestVerificationOnUnverifiedEmail {
                    await requestEmailVerification()
                    // Keep the recovery controls reachable even when the
                    // verification-email provider is temporarily unavailable.
                    if emailEntryMode != .emailVerification {
                        withAnimation(.snappy(duration: 0.18)) {
                            emailEntryMode = .emailVerification
                        }
                    }
                } else {
                    withAnimation(.snappy(duration: 0.18)) {
                        emailEntryMode = .emailVerification
                        self.error = L10n.string(
                            "mobile.signIn.verificationPending",
                            defaultValue: "That email is not verified yet. Open the verification link, then try again."
                        )
                    }
                }
            } else {
                self.error = detailedErrorMessage(error)
            }
            analytics.capture("ios_sign_in_failed", [
                "method": .string("email_code"),
                "failure_reason": .string(signInFailureReason(error)),
            ])
        }
    }

    private func requestEmailVerification() async {
        guard !isRequestingEmailVerification else { return }
        error = nil
        billingRecoveryMessage = nil
        isEmailFocused = false
        isRequestingEmailVerification = true
        defer { isRequestingEmailVerification = false }
        analytics.capture("ios_email_verification_requested", [:])
        do {
            try await authManager.requestEmailVerification(for: normalizedEmail)
            withAnimation(.snappy(duration: 0.18)) {
                emailEntryMode = .emailVerification
            }
        } catch {
            if case AuthError.cancelled = error {
                return
            }
            self.error = detailedErrorMessage(error)
            analytics.capture("ios_email_verification_request_failed", [
                "failure_reason": .string(signInFailureReason(error)),
            ])
        }
    }

    private func requestBillingRecovery() async {
        guard !isRequestingBillingRecovery else { return }
        error = nil
        billingRecoveryMessage = nil
        isEmailFocused = false
        isRequestingBillingRecovery = true
        defer { isRequestingBillingRecovery = false }
        analytics.capture("ios_billing_recovery_attempted", [:])
        do {
            try await authManager.requestBillingRecovery(for: normalizedEmail)
            billingRecoveryMessage = L10n.string(
                "mobile.signIn.billingRecoverySent",
                defaultValue: "Request accepted. If you do not receive an email, try again later."
            )
        } catch {
            if case AuthError.cancelled = error {
                return
            }
            self.error = detailedErrorMessage(error)
            analytics.capture("ios_billing_recovery_failed", [
                "failure_reason": .string(signInFailureReason(error)),
            ])
        }
    }

    private func returnToSignInMethods() {
        withAnimation(.snappy(duration: 0.18)) {
            shouldAutofocusEmail = false
            shouldShowBillingRecovery = false
            billingRecoveryMessage = nil
            emailEntryMode = .methods
            error = nil
        }
    }

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func verifyCode() async {
        error = nil
        diagnosticLog?.recordAppEvent(.authVerificationStarted)
        do {
            try await authManager.verifyCode(code)
            diagnosticLog?.recordAppEvent(.authSignInSucceeded)
        } catch {
            if case AuthError.cancelled = error {
                diagnosticLog?.recordAppEvent(.authSignInCancelled)
                analytics.capture("ios_sign_in_cancelled", ["method": .string("email_code")])
                return
            }
            self.error = detailedErrorMessage(error)
            code = ""
            diagnosticLog?.recordAppEvent(
                .authSignInFailed,
                failure: DiagnosticFailureKind.classify(error)
            )
            analytics.capture("ios_sign_in_failed", [
                "method": .string("email_code"),
                "failure_reason": .string(signInFailureReason(error)),
            ])
        }
    }

    private func signIn(with provider: OAuthSignInProvider) async {
        error = nil
        signingInProviders.insert(provider)
        defer { signingInProviders.remove(provider) }
        diagnosticLog?.recordAppEvent(.authSignInStarted)
        analytics.capture("ios_sign_in_started", ["method": .string(provider.analyticsMethod)])
        do {
            try await provider.signIn(using: authManager)
            diagnosticLog?.recordAppEvent(.authSignInSucceeded)
        } catch {
            if case AuthError.cancelled = error {
                diagnosticLog?.recordAppEvent(.authSignInCancelled)
                analytics.capture("ios_sign_in_cancelled", ["method": .string(provider.analyticsMethod)])
                return
            }
            if let stackError = error as? StackAuthErrorProtocol, stackError.code == "oauth_cancelled" {
                diagnosticLog?.recordAppEvent(.authSignInCancelled)
                analytics.capture("ios_sign_in_cancelled", ["method": .string(provider.analyticsMethod)])
                return
            }
            self.error = detailedErrorMessage(error)
            diagnosticLog?.recordAppEvent(
                .authSignInFailed,
                failure: DiagnosticFailureKind.classify(error)
            )
            analytics.capture("ios_sign_in_failed", [
                "method": .string(provider.analyticsMethod),
                "failure_reason": .string(signInFailureReason(error)),
            ])
        }
    }

    /// Maps a sign-in error to the `ios_sign_in_failed` `failure_reason` enum
    /// (enums only, never the error text or the user's email).
    private func signInFailureReason(_ error: Error) -> String {
        errorPresentation.failureReason(for: error)
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityIdentifier("signin.error")
    }

    private func detailedErrorMessage(_ error: Error) -> String {
        errorPresentation.message(for: error)
    }

    private func authCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: 430)
            .frame(maxWidth: .infinity)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIApplication.shared.dismissMobileKeyboard()
                    }
            )
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image("CmuxLogo")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            Text(L10n.string("mobile.signIn.title", defaultValue: "cmux"))
                .font(.system(.title2, design: .default, weight: .semibold))
                .tracking(-0.33)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 2)
    }

}
