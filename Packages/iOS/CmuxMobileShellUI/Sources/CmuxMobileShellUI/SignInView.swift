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
    @State private var isAppleSigningIn = false
    @State private var isGoogleSigningIn = false
    @State private var shouldAutofocusCode = false
    @State private var shouldAutofocusEmail = false
    @State private var signInTask: Task<Void, Never>?
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

                Button {
                    signInTask = Task {
                        await signInWithApple()
                    }
                } label: {
                    Group {
                        Label(L10n.string("mobile.signIn.apple", defaultValue: "Sign in with Apple"), systemImage: "apple.logo")
                            .fontWeight(.semibold)
                            .mobileButtonLoading(isAppleSigningIn)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.capsule)
                }
                .disabled(isAuthInProgress)
                .mobileGlassButton()
                .accessibilityIdentifier("signin.apple")

                Button {
                    signInTask = Task {
                        await signInWithGoogle()
                    }
                } label: {
                    Group {
                        HStack(spacing: 6) {
                            Image("GoogleLogo")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 16, height: 16)
                                .accessibilityHidden(true)
                            Text(L10n.string("mobile.signIn.google", defaultValue: "Sign in with Google"))
                                .fontWeight(.semibold)
                        }
                        .mobileButtonLoading(isGoogleSigningIn)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.capsule)
                }
                .disabled(isAuthInProgress)
                .mobileGlassButton()
                .accessibilityIdentifier("signin.google")

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
                        signInTask = Task {
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

                cancelSignInButton
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
                                signInTask = Task {
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

                cancelSignInButton

                Button {
                    signInTask = Task {
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

    private var isAuthInProgress: Bool {
        authManager.isLoading || isAppleSigningIn || isGoogleSigningIn
    }

    /// Escape hatch while a sign-in flow is in flight: cancels the running
    /// task, which tears down any presented system auth sheet and ends the
    /// loading state silently (no error). Without this, a stuck flow left the
    /// whole screen disabled with no way out.
    @ViewBuilder
    private var cancelSignInButton: some View {
        if isAuthInProgress {
            Button {
                signInTask?.cancel()
            } label: {
                Text(L10n.string("mobile.signIn.cancel", defaultValue: "Cancel"))
                    .font(.subheadline)
            }
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("signin.cancel")
        }
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
                "failure_reason": .string(Self.signInFailureReason(error)),
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
                "failure_reason": .string(Self.signInFailureReason(error)),
            ])
        }
    }

    private func signInWithApple() async {
        error = nil
        isAppleSigningIn = true
        defer { isAppleSigningIn = false }
        analytics.capture("ios_sign_in_started", ["method": .string("apple")])
        do {
            try await authManager.signInWithApple()
        } catch {
            if case AuthError.cancelled = error {
                analytics.capture("ios_sign_in_cancelled", ["method": .string("apple")])
                return
            }
            if let stackError = error as? StackAuthErrorProtocol, stackError.code == "oauth_cancelled" {
                analytics.capture("ios_sign_in_cancelled", ["method": .string("apple")])
                return
            }
            self.error = detailedErrorMessage(error)
            analytics.capture("ios_sign_in_failed", [
                "method": .string("apple"),
                "failure_reason": .string(Self.signInFailureReason(error)),
            ])
        }
    }

    private func signInWithGoogle() async {
        error = nil
        isGoogleSigningIn = true
        defer { isGoogleSigningIn = false }
        analytics.capture("ios_sign_in_started", ["method": .string("google")])
        do {
            try await authManager.signInWithGoogle()
        } catch {
            if case AuthError.cancelled = error {
                analytics.capture("ios_sign_in_cancelled", ["method": .string("google")])
                return
            }
            if let stackError = error as? StackAuthErrorProtocol, stackError.code == "oauth_cancelled" {
                analytics.capture("ios_sign_in_cancelled", ["method": .string("google")])
                return
            }
            self.error = detailedErrorMessage(error)
            analytics.capture("ios_sign_in_failed", [
                "method": .string("google"),
                "failure_reason": .string(Self.signInFailureReason(error)),
            ])
        }
    }

    /// Maps a sign-in error to the `ios_sign_in_failed` `failure_reason` enum
    /// (enums only, never the error text or the user's email).
    private static func signInFailureReason(_ error: Error) -> String {
        if let authError = error as? AuthError {
            switch authError {
            case .timedOut:
                return "timeout"
            case .offline:
                return "offline"
            case .networkError:
                return "network"
            default:
                break
            }
        }
        if let stackError = error as? StackAuthErrorProtocol {
            switch stackError.code {
            case "VERIFICATION_CODE_ERROR", "INVALID_OTP", "INVALID_TOTP_CODE":
                return "invalid_code"
            case "OTP_EXPIRED":
                return "code_expired"
            case "RATE_LIMIT":
                return "rate_limit"
            default:
                return "oauth_error"
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "network"
        }
        return "other"
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
        let displayError = AuthError(displaySafe: error) ?? error
        if let stackError = displayError as? StackAuthErrorProtocol {
            switch stackError.code {
            case "SCHEMA_ERROR":
                return L10n.string("auth.error.invalid_email", defaultValue: "Please enter a valid email address.")
            case "USER_EMAIL_ALREADY_EXISTS":
                return L10n.string("auth.error.email_exists", defaultValue: "An account with this email already exists. Try signing in instead.")
            case "VERIFICATION_CODE_ERROR", "INVALID_OTP":
                return L10n.string("auth.error.invalid_code", defaultValue: "Invalid code. Please check and try again.")
            case "OTP_EXPIRED":
                return L10n.string("auth.error.code_expired", defaultValue: "Code expired. Please request a new one.")
            case "RATE_LIMIT":
                return L10n.string("auth.error.rate_limit", defaultValue: "Too many attempts. Please wait a moment and try again.")
            case "EMAIL_PASSWORD_MISMATCH":
                return L10n.string("auth.error.wrong_password", defaultValue: "Incorrect email or password.")
            case "USER_NOT_FOUND":
                return L10n.string("auth.error.user_not_found", defaultValue: "No account found with this email.")
            case "PASSKEY_AUTHENTICATION_FAILED", "PASSKEY_WEBAUTHN_ERROR":
                return L10n.string("auth.error.passkey_failed", defaultValue: "Passkey authentication failed. Please try again.")
            case "INVALID_TOTP_CODE":
                return L10n.string("auth.error.invalid_mfa", defaultValue: "Incorrect verification code. Please try again.")
            case "REDIRECT_URL_NOT_WHITELISTED":
                return L10n.string("auth.error.config", defaultValue: "Sign in is temporarily unavailable. Please try again later.")
            case "OAUTH_PROVIDER_ACCOUNT_ID_ALREADY_USED_FOR_SIGN_IN":
                return L10n.string("auth.error.oauth_linked", defaultValue: "This account is already linked to another sign-in method.")
            case "INVALID_APPLE_CREDENTIALS":
                return L10n.string("auth.error.apple_config", defaultValue: "Apple Sign In is not available yet. Please use another sign-in method.")
            case "oauth_cancelled":
                return ""
            default:
                break
            }
        }

        if let authError = displayError as? AuthError {
            return authError.localizedDescription
        }

        let nsError = displayError as NSError
        if nsError.domain == NSURLErrorDomain {
            return L10n.string("auth.error.network", defaultValue: "Could not connect to the server. Check your internet connection and try again.")
        }

        #if DEBUG
        var debug = "\(displayError.localizedDescription)\n\(String(reflecting: type(of: displayError)))"
        if let stackError = displayError as? StackAuthErrorProtocol {
            debug += "\ncode: \(stackError.code)\nmessage: \(stackError.message)"
            if let details = stackError.details {
                debug += "\ndetails: \(details)"
            }
        }
        return debug
        #else
        return L10n.string("auth.error.generic", defaultValue: "Something went wrong. Please try again.")
        #endif
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
