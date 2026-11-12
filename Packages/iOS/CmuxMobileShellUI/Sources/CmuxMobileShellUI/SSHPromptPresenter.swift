#if os(iOS)
import CmuxMobileSSH
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI
import UIKit

extension View {
    /// Presents the SSH runtime's questions (trust a new server, a changed
    /// server identity) above every screen,
    /// including open sheets and the workspace terminal. Mount once at the
    /// app root.
    ///
    /// A connection can ask while any sheet is up (installing a key from the
    /// host form asks to trust the server), and SwiftUI cannot present from a
    /// view that is already presenting, so the prompt lives in its own window
    /// above the app's, like a system alert.
    func sshPromptPresenter(_ computers: MobileSSHComputers) -> some View {
        background(
            SSHPromptWindowMounter(
                computers: computers,
                pendingPromptID: computers.prompts.first?.id
            )
        )
    }
}

/// Zero-size anchor that finds the scene and shows/hides the prompt window as
/// the first pending prompt changes. `pendingPromptID` is read in the parent's
/// body, so observation drives `updateUIView` without any polling.
private struct SSHPromptWindowMounter: UIViewRepresentable {
    let computers: MobileSSHComputers
    let pendingPromptID: String?

    func makeCoordinator() -> SSHPromptWindowCoordinator {
        SSHPromptWindowCoordinator(computers: computers)
    }

    func makeUIView(context: Context) -> SSHPromptAnchorView {
        let view = SSHPromptAnchorView()
        view.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        view.onWindowSceneChanged = { [weak coordinator] scene in
            coordinator?.windowSceneChanged(scene)
        }
        return view
    }

    func updateUIView(_ uiView: SSHPromptAnchorView, context: Context) {
        context.coordinator.pendingPromptChanged(hasPrompt: pendingPromptID != nil)
    }

    static func dismantleUIView(_ uiView: SSHPromptAnchorView, coordinator: SSHPromptWindowCoordinator) {
        coordinator.teardown()
    }
}

private final class SSHPromptAnchorView: UIView {
    var onWindowSceneChanged: ((UIWindowScene?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowSceneChanged?(window?.windowScene)
    }
}

/// Owns the prompt window. The window is visible only while a prompt is
/// pending or its sheet is still animating away, so it never intercepts
/// touches otherwise.
@MainActor
private final class SSHPromptWindowCoordinator {
    private let computers: MobileSSHComputers
    private var scene: UIWindowScene?
    private var window: UIWindow?
    private var hasPrompt = false

    init(computers: MobileSSHComputers) {
        self.computers = computers
    }

    func windowSceneChanged(_ scene: UIWindowScene?) {
        guard let scene, scene !== self.scene else { return }
        self.scene = scene
        window?.isHidden = true
        window = nil
        if hasPrompt { show() }
    }

    func pendingPromptChanged(hasPrompt: Bool) {
        self.hasPrompt = hasPrompt
        if hasPrompt { show() }
    }

    private func show() {
        guard let scene else { return }
        if let window {
            if window.isHidden { window.isHidden = false }
            return
        }
        let host = UIHostingController(
            rootView: SSHPromptWindowRoot(computers: computers) { [weak self] in
                self?.promptSheetDidDismiss()
            }
        )
        host.view.backgroundColor = .clear
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert
        window.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }

    /// The sheet finished dismissing; hide unless another prompt is waiting.
    private func promptSheetDidDismiss() {
        guard computers.prompts.isEmpty else { return }
        window?.isHidden = true
    }

    func teardown() {
        window?.isHidden = true
        window = nil
    }
}

/// Root of the prompt window: a clear view that presents the first pending
/// prompt as a sheet. A swipe-down dismissal answers Cancel.
private struct SSHPromptWindowRoot: View {
    let computers: MobileSSHComputers
    let didDismiss: () -> Void

    var body: some View {
        // Read in body so observation re-renders when the queue changes.
        let current = computers.prompts.first
        Color.clear
            .ignoresSafeArea()
            .sheet(item: promptBinding(current), onDismiss: didDismiss) { prompt in
                SSHPromptSheet(prompt: prompt) { answer in
                    computers.answer(prompt, with: answer)
                }
            }
    }

    private func promptBinding(_ current: MobileSSHPrompt?) -> Binding<MobileSSHPrompt?> {
        Binding(
            get: { current },
            set: { newValue in
                // Interactive dismissal of a still-pending prompt cancels it.
                guard newValue == nil, let current else { return }
                computers.answer(current, with: .cancel)
            }
        )
    }
}

/// Renders one prompt. Value-only: answers go back through `answer`.
struct SSHPromptSheet: View {
    let prompt: MobileSSHPrompt
    let answer: (MobileSSHPromptAnswer) -> Void

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(SSHCopy().cancel) { answer(.cancel) }
                            .accessibilityIdentifier("ssh.prompt.cancel")
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var content: some View {
        switch prompt {
        case .trustNewHostKey(let host, let key):
            SSHTrustHostKeyContent(host: host, key: key, answer: answer)
        case .hostKeyChanged(let host, let pinned, let presented):
            SSHHostKeyChangedContent(host: host, pinned: pinned, presented: presented, answer: answer)
        }
    }
}

// MARK: Trust on first use

private struct SSHTrustHostKeyContent: View {
    let host: SSHHostRecord
    let key: SSHHostKey
    let answer: (MobileSSHPromptAnswer) -> Void

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        L10n.string("mobile.ssh.prompt.trust.title", defaultValue: "Trust this computer?"),
                        systemImage: "lock.shield"
                    )
                    .font(.title3.weight(.semibold))
                    Text(L10n.string(
                        "mobile.ssh.prompt.trust.explanation",
                        defaultValue: "This is the first time this iPhone connects to this computer. cmux will remember its identity and warn you if it ever changes. If you're unsure, compare the fingerprint below with the one the server shows (ssh-keygen -lf on its host key)."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent(L10n.string("mobile.ssh.prompt.computer", defaultValue: "Computer"), value: host.name)
                LabeledContent(
                    L10n.string("mobile.ssh.prompt.address", defaultValue: "Address"),
                    value: host.endpoint.sshDisplayAddress
                )
                LabeledContent(L10n.string("mobile.ssh.prompt.algorithm", defaultValue: "Key Type"), value: key.algorithm)
                SSHFingerprintRow(
                    title: L10n.string("mobile.ssh.prompt.fingerprint", defaultValue: "SHA256 Fingerprint"),
                    fingerprint: key.sha256Fingerprint,
                    identifier: "ssh.prompt.fingerprint"
                )
            }
            Section {
                Button {
                    answer(.trust)
                } label: {
                    Text(L10n.string("mobile.ssh.prompt.trust.confirm", defaultValue: "Trust and Connect"))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("ssh.prompt.trust")
            }
        }
        .navigationTitle(L10n.string("mobile.ssh.prompt.trust.navTitle", defaultValue: "New Computer"))
        .accessibilityIdentifier("ssh.prompt.trustNewHostKey")
    }
}

// MARK: Changed host key (PRD D17)

private struct SSHHostKeyChangedContent: View {
    let host: SSHHostRecord
    let pinned: SSHHostKey
    let presented: SSHHostKey
    let answer: (MobileSSHPromptAnswer) -> Void

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        L10n.string("mobile.ssh.prompt.changed.title", defaultValue: "This computer's identity changed"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.red)
                    Text(String(
                        format: L10n.string(
                            "mobile.ssh.prompt.changed.explanation",
                            defaultValue: "%@ presented a different identity key than last time, so cmux stopped before connecting. Either the computer was reinstalled or recreated (common and harmless), or someone may be impersonating it to capture what you type. cmux can't tell which."
                        ),
                        host.name
                    ))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.string(
                        "mobile.ssh.prompt.changed.advice",
                        defaultValue: "Only trust the new key if you know the computer was reinstalled. If you're on public Wi-Fi or unsure, cancel."
                    ))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent(
                    L10n.string("mobile.ssh.prompt.address", defaultValue: "Address"),
                    value: host.endpoint.sshDisplayAddress
                )
                SSHFingerprintRow(
                    title: String(
                        format: L10n.string("mobile.ssh.prompt.changed.old", defaultValue: "Previous Key (%@)"),
                        pinned.algorithm
                    ),
                    fingerprint: pinned.sha256Fingerprint,
                    identifier: "ssh.prompt.fingerprint.old"
                )
                SSHFingerprintRow(
                    title: String(
                        format: L10n.string("mobile.ssh.prompt.changed.new", defaultValue: "New Key (%@)"),
                        presented.algorithm
                    ),
                    fingerprint: presented.sha256Fingerprint,
                    identifier: "ssh.prompt.fingerprint.new"
                )
            }
            // HIG Alerts: no default button here, so people read before
            // choosing; the trust action is destructive because trusting a
            // changed identity is not what the user set out to do. Each
            // centered action gets its own section: a shared section draws a
            // separator inset to the text's leading edge, which reads as
            // misaligned under centered titles.
            Section {
                Button {
                    answer(.cancel)
                } label: {
                    Text(SSHCopy().cancel)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("ssh.prompt.changed.cancel")
            }
            Section {
                Button(role: .destructive) {
                    answer(.trust)
                } label: {
                    Text(L10n.string(
                        "mobile.ssh.prompt.changed.trust",
                        defaultValue: "I Reinstalled It, Trust New Key"
                    ))
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("ssh.prompt.changed.trust")
            }
        }
        .navigationTitle(L10n.string("mobile.ssh.prompt.changed.navTitle", defaultValue: "Identity Changed"))
        .accessibilityIdentifier("ssh.prompt.hostKeyChanged")
    }
}

/// A fingerprint shown monospaced and selectable, with a copy action.
private struct SSHFingerprintRow: View {
    let title: String
    let fingerprint: String
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(fingerprint)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = fingerprint
            } label: {
                Label(SSHCopy().copy, systemImage: "doc.on.doc")
            }
        }
    }
}
#endif
