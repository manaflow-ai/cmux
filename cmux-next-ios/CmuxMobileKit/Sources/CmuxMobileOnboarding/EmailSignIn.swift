#if os(iOS)
import CmuxMobileAuth
import CmuxMobileDesign
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// Email code sign-in (SPEC 5.4): large sheet, "Email" step then "Code" step
/// pushed inside the sheet.
struct EmailSignInSheet: View {
    let auth: CmuxMobileAuthModel
    @State private var email: String
    @State private var path: [String]
    @State private var isSending = false
    @State private var error: String?
    @FocusState private var emailFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(auth: CmuxMobileAuthModel, initialEmail: String?) {
        self.auth = auth
        _email = State(initialValue: initialEmail ?? "")
        _path = State(initialValue: initialEmail.map { $0.isEmpty ? [] : [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                // Scrolls at large text sizes; the CTA stays above the keyboard.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("What's your email?")
                            .font(theme.type.sheetTitle)
                            .foregroundStyle(theme.colors.label)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("We'll send you a code to sign in.")
                            .font(theme.type.rowSubtitle)
                            .foregroundStyle(theme.colors.label2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                        TextField("Email", text: $email, prompt: Text(verbatim: "name@example.com").foregroundStyle(theme.colors.label3))
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.continue)
                            .focused($emailFocused)
                            .font(theme.type.body)
                            .cmuxMobileInputField()
                            .padding(.top, 20)
                            .onSubmit(send)
                        if let error {
                            Text(error).font(theme.type.meta).foregroundStyle(theme.colors.dangerText).padding(.top, 10)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                // The next screen says a code was sent.
                PrimaryCapsule("Continue", isLoading: isSending, action: send)
                    .disabled(!isValidEmail)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
            }
            .padding(.horizontal, theme.metrics.sideMargin)
            .padding(.top, 8)
            .modifier(SignInSheetBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { address in
                EmailCodeStep(auth: auth, email: address) { path.removeAll() }
            }
            .background {
                EmailSheetAppearance {
                    if path.isEmpty { emailFocused = true }
                }
            }
            .onDisappear { emailFocused = false }
            #if DEBUG
            .onChange(of: DemoDirector.shared.serial) {
                switch DemoDirector.shared.command {
                case .onboardingTypeEmail(let text):
                    Task { for character in text { email.append(character); try? await Task.sleep(for: .milliseconds(55)) } }
                case .onboardingSendCode: send()
                default: break
                }
            }
            #endif
        }
        .presentationDetents([.large])
        .tint(theme.colors.label.color)
    }

    private var isValidEmail: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        #if DEBUG
        if trimmed == "42" { return true }
        #endif
        let parts = trimmed.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !parts[0].isEmpty && !trimmed.contains(" ")
    }

    private func send() {
        guard isValidEmail, !isSending else { return }
        let address = email.trimmingCharacters(in: .whitespaces)
        isSending = true
        error = nil
        Task {
            defer { isSending = false }
            do {
                try await auth.sendCode(to: address)
                if !auth.isSignedIn { path.append(address) }
            } catch {
                self.error = CmuxMobileAuthModel.message(for: error)
                theme.haptics.error()
            }
        }
    }
}

/// SwiftUI's onAppear can run before the sheet accepts first responder.
/// UIKit calls viewDidAppear after presentation (and after returning from Code),
/// so focus follows the actual transition without a timer or retry loop.
private struct EmailSheetAppearance: UIViewControllerRepresentable {
    var onAppear: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onAppear = onAppear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onAppear = onAppear
    }

    final class Controller: UIViewController {
        var onAppear: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear?()
        }
    }
}

/// Six boxes over a hidden one-time-code field; auto-submits on the sixth
/// digit; invalid codes shake and clear; resend has a 30 s countdown.
struct EmailCodeStep: View {
    let auth: CmuxMobileAuthModel
    let email: String
    let useDifferentEmail: () -> Void
    @State private var code = ""
    @State private var isVerifying = false
    @State private var shakes = 0
    @State private var error: String?
    @State private var resendAvailableAt = Date().addingTimeInterval(30)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Check your email")
                .font(theme.type.sheetTitle)
                .foregroundStyle(theme.colors.label)
            Text("Enter the code we sent to \(email).")
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2)
                .padding(.top, 6)
            CodeBoxes(text: $code)
                .modifier(ShakeEffect(trigger: shakes))
                .animation(.linear(duration: theme.motion.shakeDuration), value: shakes)
                .disabled(isVerifying)
                // Verifying: the boxes dim and the spinner sits on them.
                .opacity(isVerifying ? 0.4 : 1)
                .overlay { if isVerifying { ProgressView() } }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            if let error {
                Text(error).font(theme.type.meta).foregroundStyle(theme.colors.dangerText)
                    .frame(maxWidth: .infinity).padding(.top, 14)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(resendAvailableAt.timeIntervalSince(context.date).rounded(.up)))
                HStack {
                    Spacer()
                    TextCTA(remaining > 0 ? "Resend in 0:\(String(format: "%02d", remaining))" : "Resend code") { resend() }
                        .disabled(remaining > 0)
                        .opacity(remaining > 0 ? 0.4 : 1)
                    Spacer()
                }
            }
            .padding(.top, 20)
            HStack {
                Spacer()
                TextCTA("Use a different email", action: useDifferentEmail)
                Spacer()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .padding(.top, 8)
        .modifier(SignInSheetBackground())
        .navigationBarBackButtonHidden(false)
        .onChange(of: code) { _, value in
            if value.count == 6 { verify(value) }
        }
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) {
            if case .onboardingTypeCode(let text) = DemoDirector.shared.command {
                Task { for character in text { code.append(character); try? await Task.sleep(for: .milliseconds(140)) } }
            }
        }
        #endif
    }

    private func verify(_ value: String) {
        guard !isVerifying else { return }
        isVerifying = true
        error = nil
        Task {
            defer { isVerifying = false }
            do {
                try await auth.verifyCode(value)
                theme.haptics.success()
            } catch {
                self.error = CmuxMobileAuthModel.message(for: error) ?? "That code didn't work. Try again."
                theme.haptics.error()
                shakes += 1
                code = ""
            }
        }
    }

    private func resend() {
        resendAvailableAt = Date().addingTimeInterval(30)
        Task { try? await auth.sendCode(to: email) }
    }
}
/// The email sheet's background: `sheet` in dark; plain `bg` (white) in light,
/// where `sheet` and the `surfaceRaised` field and code boxes are the same gray
/// and the inputs would disappear (Claude and ChatGPT use white here too).
private struct SignInSheetBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background((colorScheme == .dark ? theme.colors.sheet : theme.colors.bg).color.ignoresSafeArea())
    }
}
#endif
