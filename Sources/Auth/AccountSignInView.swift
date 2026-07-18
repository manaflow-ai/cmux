import CmuxSettingsUI
import SwiftUI

/// Shared Stack sign-in status UI used by the Account and Pair iPhone panes.
struct AccountSignInView: View {
    let model: AccountSignInModel
    let automaticallyStartsSignIn: Bool

    var body: some View {
        VStack(spacing: 16) {
            switch model.phase {
            case .idle:
                AccountSignInIdleView(onSignIn: model.presentSignIn)
            case let .loading(stage):
                AccountSignInLoadingView(
                    stage: stage,
                    hasFallbackLink: model.hasFallbackLink,
                    linkCopyState: model.linkCopyState,
                    browserOpenState: model.browserOpenState,
                    onOpenInBrowser: model.openSignInInBrowser,
                    onCopyLink: model.copySignInLink
                )
            case let .failed(failure):
                AccountSignInFailureView(
                    failure: failure,
                    hasFallbackLink: model.hasFallbackLink,
                    linkCopyState: model.linkCopyState,
                    browserOpenState: model.browserOpenState,
                    onTryAgain: model.presentSignIn,
                    onOpenInBrowser: model.openSignInInBrowser,
                    onCopyLink: model.copySignInLink
                )
            case let .signedIn(identity):
                AccountSignInSuccessView(identity: identity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .task {
            if automaticallyStartsSignIn {
                model.startSignInIfNeeded()
            }
        }
        .accessibilityIdentifier("AccountSignInView")
    }
}

private struct AccountSignInIdleView: View {
    let onSignIn: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .cmuxFont(size: 34)
                .foregroundStyle(.tint)
            Text(String(localized: "account.signIn.heading", defaultValue: "Sign in to cmux"))
                .cmuxFont(.title2, weight: .semibold)
            Text(String(
                localized: "account.signIn.prompt",
                defaultValue: "Continue with your Stack account."
            ))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Button(String(localized: "account.signIn.start", defaultValue: "Sign In"), action: onSignIn)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("AccountSignInStartButton")
        }
    }
}

private struct AccountSignInLoadingView: View {
    let stage: AccountSignInModel.LoadingStage
    let hasFallbackLink: Bool
    let linkCopyState: AccountSignInModel.LinkCopyState
    let browserOpenState: AccountSignInModel.BrowserOpenState
    let onOpenInBrowser: () -> Void
    let onCopyLink: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(stage.title)
            Text(stage.title)
                .cmuxFont(.headline)
            Text(stage.instructions)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if hasFallbackLink, stage.showsFallbackActions {
                AccountSignInFallbackActions(
                    linkCopyState: linkCopyState,
                    browserOpenState: browserOpenState,
                    onOpenInBrowser: onOpenInBrowser,
                    onCopyLink: onCopyLink
                )
            }
        }
        .frame(maxWidth: 440)
        .accessibilityIdentifier("AccountSignInLoadingState")
    }
}

private struct AccountSignInFailureView: View {
    let failure: AccountSignInModel.Failure
    let hasFallbackLink: Bool
    let linkCopyState: AccountSignInModel.LinkCopyState
    let browserOpenState: AccountSignInModel.BrowserOpenState
    let onTryAgain: () -> Void
    let onOpenInBrowser: () -> Void
    let onCopyLink: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .cmuxFont(size: 30)
                .foregroundStyle(.orange)
            Text(failure.title)
                .cmuxFont(.headline)
            Text(failure.recovery)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "account.signIn.tryAgain", defaultValue: "Try Again"), action: onTryAgain)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("AccountSignInRetryButton")
            if hasFallbackLink {
                AccountSignInFallbackActions(
                    linkCopyState: linkCopyState,
                    browserOpenState: browserOpenState,
                    onOpenInBrowser: onOpenInBrowser,
                    onCopyLink: onCopyLink
                )
            }
        }
        .frame(maxWidth: 440)
        .accessibilityIdentifier("AccountSignInFailureState")
    }
}

private struct AccountSignInSuccessView: View {
    let identity: AccountIdentity

    var body: some View {
        VStack(spacing: 12) {
            StackAccountAvatarView(
                avatarURL: identity.avatarURL,
                displayName: identity.displayName,
                email: identity.email,
                size: 56
            )
            Text(String(localized: "account.signIn.successTitle", defaultValue: "You’re signed in now"))
                .cmuxFont(.title2, weight: .semibold)
            Text(identity.displayName.isEmpty ? identity.email : identity.displayName)
                .cmuxFont(.headline)
                .lineLimit(1)
            if !identity.email.isEmpty && identity.email != identity.displayName {
                Text(identity.email)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(String(
                localized: "account.signIn.successBody",
                defaultValue: "cmux is connected to your Stack account."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("AccountSignInSuccessState")
    }
}

private struct AccountSignInFallbackActions: View {
    let linkCopyState: AccountSignInModel.LinkCopyState
    let browserOpenState: AccountSignInModel.BrowserOpenState
    let onOpenInBrowser: () -> Void
    let onCopyLink: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(
                    String(localized: "account.signIn.openInBrowser", defaultValue: "Open Again in Browser"),
                    action: onOpenInBrowser
                )
                .accessibilityIdentifier("AccountSignInOpenBrowserButton")
                Button(
                    String(localized: "account.signIn.copyLink", defaultValue: "Copy Sign-In Link"),
                    action: onCopyLink
                )
                .accessibilityIdentifier("AccountSignInCopyLinkButton")
            }
            .controlSize(.small)

            if linkCopyState == .copied {
                Text(String(localized: "account.signIn.linkCopied", defaultValue: "Link copied"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AccountSignInLinkCopied")
            } else if linkCopyState == .failed {
                Text(String(
                    localized: "account.signIn.copyFailed",
                    defaultValue: "Couldn’t copy the link. Open it in your browser instead."
                ))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("AccountSignInCopyFailed")
            } else if browserOpenState == .opened {
                Text(String(
                    localized: "account.signIn.browserOpened",
                    defaultValue: "Browser opened. Complete sign-in there."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AccountSignInBrowserOpened")
            } else if browserOpenState == .failed {
                Text(String(
                    localized: "account.signIn.browserOpenFailed",
                    defaultValue: "Couldn’t open your browser. Copy the link and paste it into any browser."
                ))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("AccountSignInBrowserOpenFailed")
            }
        }
    }
}

private extension AccountSignInModel.LoadingStage {
    var title: String {
        switch self {
        case .openingBrowser:
            return String(localized: "account.signIn.loading.opening", defaultValue: "Opening secure sign-in…")
        case .waiting:
            return String(localized: "account.signIn.loading.waiting", defaultValue: "Waiting for sign-in…")
        case .waitingSlow:
            return String(localized: "account.signIn.loading.waitingSlow", defaultValue: "Still waiting for sign-in…")
        case .finishing:
            return String(localized: "account.signIn.loading.finishing", defaultValue: "Finishing sign-in…")
        }
    }

    var instructions: String {
        switch self {
        case .openingBrowser:
            return String(
                localized: "account.signIn.loading.opening.instructions",
                defaultValue: "cmux is preparing a secure Stack sign-in window."
            )
        case .waiting:
            return String(
                localized: "account.signIn.loading.waiting.instructions",
                defaultValue: "Complete sign-in in the window that opened. This pane updates automatically."
            )
        case .waitingSlow:
            return String(
                localized: "account.signIn.loading.waitingSlow.instructions",
                defaultValue: "The sign-in window is taking longer than expected. You can reopen or copy the same secure link without restarting."
            )
        case .finishing:
            return String(
                localized: "account.signIn.loading.finishing.instructions",
                defaultValue: "cmux is verifying your Stack account. Keep this pane open."
            )
        }
    }

    var showsFallbackActions: Bool {
        self == .waiting || self == .waitingSlow
    }
}

private extension AccountSignInModel.Failure {
    var title: String {
        switch self {
        case .cancelled:
            return String(localized: "account.signIn.error.cancelled.title", defaultValue: "Sign-in canceled")
        case .offline:
            return String(localized: "account.signIn.error.offline.title", defaultValue: "No internet connection")
        case .network:
            return String(localized: "account.signIn.error.network.title", defaultValue: "Couldn’t reach Stack")
        case .timedOut:
            return String(localized: "account.signIn.error.timedOut.title", defaultValue: "Sign-in timed out")
        case .server:
            return String(localized: "account.signIn.error.server.title", defaultValue: "Stack is temporarily unavailable")
        case .invalidLink:
            return String(localized: "account.signIn.error.invalidLink.title", defaultValue: "That sign-in link is no longer valid")
        case .browserUnavailable:
            return String(localized: "account.signIn.error.browserUnavailable.title", defaultValue: "Couldn’t open sign-in")
        case .unauthorized:
            return String(localized: "account.signIn.error.unauthorized.title", defaultValue: "Stack couldn’t authorize this sign-in")
        case .rejected:
            return String(localized: "account.signIn.error.rejected.title", defaultValue: "Stack rejected the sign-in")
        case .unknown:
            return String(localized: "account.signIn.error.unknown.title", defaultValue: "Couldn’t finish sign-in")
        }
    }

    var recovery: String {
        switch self {
        case .cancelled:
            return String(
                localized: "account.signIn.error.cancelled.recovery",
                defaultValue: "No changes were made. Try again when you’re ready, or use the browser link below."
            )
        case .offline:
            return String(
                localized: "account.signIn.error.offline.recovery",
                defaultValue: "Connect to Wi-Fi or another network, then try again. You can keep this pane open."
            )
        case .network:
            return String(
                localized: "account.signIn.error.network.recovery",
                defaultValue: "Check your connection, then try again. Your account was not changed."
            )
        case .timedOut:
            return String(
                localized: "account.signIn.error.timedOut.recovery",
                defaultValue: "The sign-in window did not return to cmux. Reopen the browser link or start a new attempt."
            )
        case .server:
            return String(
                localized: "account.signIn.error.server.recovery",
                defaultValue: "Try again in a moment. Your account and existing cmux workspaces are unchanged."
            )
        case .invalidLink:
            return String(
                localized: "account.signIn.error.invalidLink.recovery",
                defaultValue: "Try again to create a fresh secure link. The old link cannot sign in."
            )
        case .browserUnavailable:
            return String(
                localized: "account.signIn.error.browserUnavailable.recovery",
                defaultValue: "Open the link in your browser, or copy it and paste it into any browser."
            )
        case .unauthorized:
            return String(
                localized: "account.signIn.error.unauthorized.recovery",
                defaultValue: "Confirm you’re using the intended Stack account, then try again."
            )
        case .rejected:
            return String(
                localized: "account.signIn.error.rejected.recovery",
                defaultValue: "Check the account details in the browser and try again."
            )
        case .unknown:
            return String(
                localized: "account.signIn.error.unknown.recovery",
                defaultValue: "Try again. If the sign-in window still fails, copy the link and open it in your browser."
            )
        }
    }
}
