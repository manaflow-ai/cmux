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
    @Environment(AuthCoordinator.self) private var authManager
    @Environment(\.analytics) private var analytics
    @State private var email = ""
    @State private var code = ""
    @State private var showCodeEntry = false
    @State private var error: String?
    @State private var signingInProviders: Set<OAuthSignInProvider> = []
    @State private var shouldAutofocusCode = false
    @State private var shouldAutofocusEmail = false
    private let errorPresentation = SignInErrorPresentation()
    @FocusState private var isEmailFocused: Bool
    @FocusState private var isCodeFocused: Bool
    var body: some View {
        NavigationStack {
            ZStack {
                GameOfLifeHeader()
                    .ignoresSafeArea()

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIApplication.shared.dismissMobileKeyboard()
                    }
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    signInEntrySwitcher
                }
            }
            .mobileInlineNavigationTitle()
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
        if showCodeEntry {
            codeEntryView
        } else {
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
                }
                .disabled(code.count != 6 || isAuthInProgress)
                .mobileGlassProminentButton()
                .accessibilityIdentifier("signin.verifyCode")

                Button {
                    let autofocusEmailOnReturn = isCodeFocused
                    withAnimation(.snappy(duration: 0.18)) {
                        shouldAutofocusEmail = autofocusEmailOnReturn
                        showCodeEntry = false
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
    // password + 2FA) the system sheet sits above this view and carries its own
    // Cancel, and every coordinator phase is raced against a deadline
    // (AuthTimeouts), so a wedged flow always ends in a localized, retryable
    // AuthError and re-enables the card for retry. Do not reintroduce a manual
    // cancel button here; it was occluded during the system sheet anyway.
    private var isInteractiveAuthInProgress: Bool {
        authManager.isLoading || !signingInProviders.isEmpty
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

    private func sendCode(autofocusCodeOnSuccess: Bool) async {
        error = nil
        analytics.capture("ios_sign_in_started", ["method": .string("email_code")])
        do {
            try await authManager.sendCode(to: email)
            guard !authManager.isAuthenticated else {
                return
            }
            shouldAutofocusCode = autofocusCodeOnSuccess
            withAnimation(.snappy(duration: 0.18)) {
                showCodeEntry = true
            }
        } catch {
            if case AuthError.cancelled = error {
                analytics.capture("ios_sign_in_cancelled", ["method": .string("email_code")])
                return
            }
            shouldAutofocusCode = false
            self.error = detailedErrorMessage(error)
            analytics.capture("ios_sign_in_failed", [
                "method": .string("email_code"),
                "failure_reason": .string(signInFailureReason(error)),
            ])
        }
    }

    private func verifyCode() async {
        error = nil
        do {
            try await authManager.verifyCode(code)
        } catch {
            if case AuthError.cancelled = error {
                analytics.capture("ios_sign_in_cancelled", ["method": .string("email_code")])
                return
            }
            self.error = detailedErrorMessage(error)
            code = ""
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
        analytics.capture("ios_sign_in_started", ["method": .string(provider.analyticsMethod)])
        do {
            try await provider.signIn(using: authManager)
        } catch {
            if case AuthError.cancelled = error {
                analytics.capture("ios_sign_in_cancelled", ["method": .string(provider.analyticsMethod)])
                return
            }
            if let stackError = error as? StackAuthErrorProtocol, stackError.code == "oauth_cancelled" {
                analytics.capture("ios_sign_in_cancelled", ["method": .string(provider.analyticsMethod)])
                return
            }
            self.error = detailedErrorMessage(error)
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
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 2)
    }

}
