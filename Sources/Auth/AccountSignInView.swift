import AppKit
import CmuxFoundation
import CmuxSettingsUI
import Observation

/// Shared native Stack sign-in status UI used by the Account and Pair iPhone panes.
@MainActor
final class AccountSignInView: NSView {
    private struct Snapshot: Equatable {
        let phase: AccountSignInModel.Phase
        let hasFallbackLink: Bool
        let linkCopyState: AccountSignInModel.LinkCopyState
        let browserOpenState: AccountSignInModel.BrowserOpenState
    }

    private let model: AccountSignInModel
    private let automaticallyStartsSignIn: Bool
    private var lastSnapshot: Snapshot?
    private var didStartAutomatically = false

    init(model: AccountSignInModel, automaticallyStartsSignIn: Bool) {
        self.model = model
        self.automaticallyStartsSignIn = automaticallyStartsSignIn
        super.init(frame: .zero)
        setAccessibilityIdentifier("AccountSignInView")
        observeAndRender()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 240) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, automaticallyStartsSignIn, !didStartAutomatically else { return }
        didStartAutomatically = true
        model.startSignInIfNeeded()
    }

    private func observeAndRender() {
        let snapshot = withObservationTracking {
            Snapshot(
                phase: model.phase,
                hasFallbackLink: model.hasFallbackLink,
                linkCopyState: model.linkCopyState,
                browserOpenState: model.browserOpenState
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAndRender() }
        }
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        render(snapshot)
    }

    private func render(_ snapshot: Snapshot) {
        subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        switch snapshot.phase {
        case .idle:
            content = idleView()
        case .loading(let stage):
            content = loadingView(stage: stage, snapshot: snapshot)
        case .failed(let failure):
            content = failureView(failure: failure, snapshot: snapshot)
        case .signedIn(let identity):
            content = successView(identity: identity)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
        ])
    }

    private func idleView() -> NSView {
        let icon = symbol("person.crop.circle.badge.plus", pointSize: 34, color: .controlAccentColor)
        let heading = label(
            String(localized: "account.signIn.heading", defaultValue: "Sign in to cmux"),
            size: 20,
            weight: .semibold
        )
        let prompt = wrappingLabel(String(
            localized: "account.signIn.prompt",
            defaultValue: "Continue with your Stack account."
        ))
        let signIn = AccountSignInButton(
            title: String(localized: "account.signIn.start", defaultValue: "Sign In"),
            bezelStyle: .rounded,
            action: { [weak model] in model?.presentSignIn() }
        )
        signIn.keyEquivalent = "\r"
        signIn.setAccessibilityIdentifier("AccountSignInStartButton")
        return vertical([icon, heading, prompt, signIn])
    }

    private func loadingView(stage: AccountSignInModel.LoadingStage, snapshot: Snapshot) -> NSView {
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        progress.setAccessibilityLabel(stage.title)
        var views: [NSView] = [
            progress,
            label(stage.title, size: 13, weight: .semibold),
            wrappingLabel(stage.instructions),
        ]
        if snapshot.hasFallbackLink, stage.showsFallbackActions {
            views.append(fallbackActions(snapshot))
        }
        let result = vertical(views)
        result.setAccessibilityIdentifier("AccountSignInLoadingState")
        return result
    }

    private func failureView(failure: AccountSignInModel.Failure, snapshot: Snapshot) -> NSView {
        var views: [NSView] = [
            symbol("exclamationmark.triangle", pointSize: 30, color: .systemOrange),
            label(failure.title, size: 13, weight: .semibold),
            wrappingLabel(failure.recovery),
        ]
        let retry = AccountSignInButton(
            title: String(localized: "account.signIn.tryAgain", defaultValue: "Try Again"),
            bezelStyle: .rounded,
            action: { [weak model] in model?.presentSignIn() }
        )
        retry.keyEquivalent = "\r"
        retry.setAccessibilityIdentifier("AccountSignInRetryButton")
        views.append(retry)
        if snapshot.hasFallbackLink { views.append(fallbackActions(snapshot)) }
        let result = vertical(views)
        result.setAccessibilityIdentifier("AccountSignInFailureState")
        return result
    }

    private func successView(identity: AccountIdentity) -> NSView {
        let avatar = StackAccountAvatarView(
            avatarURL: identity.avatarURL,
            displayName: identity.displayName,
            email: identity.email,
            size: 56
        )
        var views: [NSView] = [
            avatar,
            label(
                String(localized: "account.signIn.successTitle", defaultValue: "You’re signed in now"),
                size: 20,
                weight: .semibold
            ),
            label(identity.displayName.isEmpty ? identity.email : identity.displayName, size: 13, weight: .semibold),
        ]
        if !identity.email.isEmpty, identity.email != identity.displayName {
            let email = label(identity.email, size: 13)
            email.textColor = .secondaryLabelColor
            views.append(email)
        }
        let body = label(
            String(localized: "account.signIn.successBody", defaultValue: "cmux is connected to your Stack account."),
            size: 11
        )
        body.textColor = .secondaryLabelColor
        views.append(body)
        let result = vertical(views)
        result.setAccessibilityIdentifier("AccountSignInSuccessState")
        return result
    }

    private func fallbackActions(_ snapshot: Snapshot) -> NSView {
        let open = AccountSignInButton(
            title: String(localized: "account.signIn.openInBrowser", defaultValue: "Open Again in Browser"),
            bezelStyle: .rounded,
            action: { [weak model] in model?.openSignInInBrowser() }
        )
        open.controlSize = .small
        open.setAccessibilityIdentifier("AccountSignInOpenBrowserButton")
        let copy = AccountSignInButton(
            title: String(localized: "account.signIn.copyLink", defaultValue: "Copy Sign-In Link"),
            bezelStyle: .rounded,
            action: { [weak model] in model?.copySignInLink() }
        )
        copy.controlSize = .small
        copy.setAccessibilityIdentifier("AccountSignInCopyLinkButton")
        let actions = NSStackView(views: [open, copy])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        var views: [NSView] = [actions]
        let status: (String, NSColor, String)? = switch (snapshot.linkCopyState, snapshot.browserOpenState) {
        case (.copied, _): (
            String(localized: "account.signIn.linkCopied", defaultValue: "Link copied"),
            .secondaryLabelColor,
            "AccountSignInLinkCopied"
        )
        case (.failed, _): (
            String(localized: "account.signIn.copyFailed", defaultValue: "Couldn’t copy the link. Open it in your browser instead."),
            .systemOrange,
            "AccountSignInCopyFailed"
        )
        case (_, .opened): (
            String(localized: "account.signIn.browserOpened", defaultValue: "Browser opened. Complete sign-in there."),
            .secondaryLabelColor,
            "AccountSignInBrowserOpened"
        )
        case (_, .failed): (
            String(localized: "account.signIn.browserOpenFailed", defaultValue: "Couldn’t open your browser. Copy the link and paste it into any browser."),
            .systemOrange,
            "AccountSignInBrowserOpenFailed"
        )
        default: nil
        }
        if let status {
            let message = wrappingLabel(status.0)
            message.font = GlobalFontMagnification.systemFont(ofSize: 11)
            message.textColor = status.1
            message.setAccessibilityIdentifier(status.2)
            views.append(message)
        }
        return vertical(views, spacing: 8)
    }

    private func vertical(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = spacing
        return stack
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = GlobalFontMagnification.systemFont(ofSize: size, weight: weight)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = GlobalFontMagnification.systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 440
        return label
    }

    private func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = color
        return view
    }
}

@MainActor
private final class AccountSignInButton: NSButton {
    private let closure: () -> Void

    init(title: String, bezelStyle: NSButton.BezelStyle, action: @escaping () -> Void) {
        closure = action
        super.init(frame: .zero)
        self.title = title
        self.bezelStyle = bezelStyle
        target = self
        self.action = #selector(invoke)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() { closure() }
}

extension AccountSignInModel.LoadingStage {
    var title: String {
        switch self {
        case .openingBrowser:
            String(localized: "account.signIn.loading.opening", defaultValue: "Opening secure sign-in…")
        case .waiting:
            String(localized: "account.signIn.loading.waiting", defaultValue: "Waiting for sign-in…")
        case .waitingSlow:
            String(localized: "account.signIn.loading.waitingSlow", defaultValue: "Still waiting for sign-in…")
        case .finishing:
            String(localized: "account.signIn.loading.finishing", defaultValue: "Finishing sign-in…")
        }
    }

    var instructions: String {
        switch self {
        case .openingBrowser:
            String(localized: "account.signIn.loading.opening.instructions", defaultValue: "cmux is preparing a secure Stack sign-in window.")
        case .waiting:
            String(localized: "account.signIn.loading.waiting.instructions", defaultValue: "Complete sign-in in the window that opened. This pane updates automatically.")
        case .waitingSlow:
            String(localized: "account.signIn.loading.waitingSlow.instructions", defaultValue: "The sign-in window is taking longer than expected. You can reopen or copy the same secure link without restarting.")
        case .finishing:
            String(localized: "account.signIn.loading.finishing.instructions", defaultValue: "cmux is verifying your Stack account. Keep this pane open.")
        }
    }

    var showsFallbackActions: Bool { self == .waiting || self == .waitingSlow }
}

extension AccountSignInModel.Failure {
    var title: String {
        switch self {
        case .cancelled: String(localized: "account.signIn.error.cancelled.title", defaultValue: "Sign-in canceled")
        case .offline: String(localized: "account.signIn.error.offline.title", defaultValue: "No internet connection")
        case .network: String(localized: "account.signIn.error.network.title", defaultValue: "Couldn’t reach Stack")
        case .timedOut: String(localized: "account.signIn.error.timedOut.title", defaultValue: "Sign-in timed out")
        case .server: String(localized: "account.signIn.error.server.title", defaultValue: "Stack is temporarily unavailable")
        case .invalidLink: String(localized: "account.signIn.error.invalidLink.title", defaultValue: "That sign-in link is no longer valid")
        case .browserUnavailable: String(localized: "account.signIn.error.browserUnavailable.title", defaultValue: "Couldn’t open sign-in")
        case .unauthorized: String(localized: "account.signIn.error.unauthorized.title", defaultValue: "Stack couldn’t authorize this sign-in")
        case .rejected: String(localized: "account.signIn.error.rejected.title", defaultValue: "Stack rejected the sign-in")
        case .unknown: String(localized: "account.signIn.error.unknown.title", defaultValue: "Couldn’t finish sign-in")
        }
    }

    var recovery: String {
        switch self {
        case .cancelled:
            String(localized: "account.signIn.error.cancelled.recovery", defaultValue: "No changes were made. Try again when you’re ready, or use the browser link below.")
        case .offline:
            String(localized: "account.signIn.error.offline.recovery", defaultValue: "Connect to Wi-Fi or another network, then try again. You can keep this pane open.")
        case .network:
            String(localized: "account.signIn.error.network.recovery", defaultValue: "Check your connection, then try again. Your account was not changed.")
        case .timedOut:
            String(localized: "account.signIn.error.timedOut.recovery", defaultValue: "The sign-in window did not return to cmux. Reopen the browser link or start a new attempt.")
        case .server:
            String(localized: "account.signIn.error.server.recovery", defaultValue: "Try again in a moment. Your account and existing cmux workspaces are unchanged.")
        case .invalidLink:
            String(localized: "account.signIn.error.invalidLink.recovery", defaultValue: "Try again to create a fresh secure link. The old link cannot sign in.")
        case .browserUnavailable:
            String(localized: "account.signIn.error.browserUnavailable.recovery", defaultValue: "Open the link in your browser, or copy it and paste it into any browser.")
        case .unauthorized:
            String(localized: "account.signIn.error.unauthorized.recovery", defaultValue: "Confirm you’re using the intended Stack account, then try again.")
        case .rejected:
            String(localized: "account.signIn.error.rejected.recovery", defaultValue: "Check the account details in the browser and try again.")
        case .unknown:
            String(localized: "account.signIn.error.unknown.recovery", defaultValue: "Try again. If the sign-in window still fails, copy the link and open it in your browser.")
        }
    }
}
