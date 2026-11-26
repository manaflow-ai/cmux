import AppKit
import CmuxNextAgentPane
public import CmuxNextCloud
public import CmuxNextDesign
public import Foundation

/// GitHub's install redirect handed back to the app (``CloudGitHubCompletion/handle(_:auth:answered:)``): a connect that
/// finished says nothing (the repository lists refresh); anything else is one toast with one way on. An organization
/// owner's pending approval reads as pending, a refusal in the API's own words, no answer as a Retry of the same link.
extension GitHubConnections {
    /// What the person reads for one completion's answer, and the toast's one action.
    public struct CompletionNotice: Equatable, Sendable {
        /// Start Connect GitHub again, or send the same completion again.
        public enum Retry: Equatable, Sendable { case connect, sendAgain }

        public let message: String
        public let retry: Retry
        public let retryTitle: String
        public let tone: CmuxToastTone

        /// Nil when GitHub connected.
        public init?(_ answer: CloudOwnerAPIClient.GitHubCompletion) {
            switch answer {
            case .connected: return nil
            case .pendingApproval: self.init(message: Self.pending, retry: .connect, retryTitle: Self.connect, tone: .neutral)
            case .refused(let said): self.init(message: said ?? Self.refused, retry: .connect, retryTitle: Self.connect, tone: .error)
            case .noAnswer: self.init(message: Self.noAnswer, retry: .sendAgain, retryTitle: Self.retryAgain, tone: .error)
            }
        }

        private init(message: String, retry: Retry, retryTitle: String, tone: CmuxToastTone) {
            self.message = message
            self.retry = retry
            self.retryTitle = retryTitle
            self.tone = tone
        }

        static let toastID = "github-complete"

        static var connect: String { String(localized: "github.connect", defaultValue: "Connect GitHub", table: "GitHubConnection", bundle: .module) }
        static var retryAgain: String { String(localized: "github.retry", defaultValue: "Retry", table: "GitHubConnection", bundle: .module) }
        static var pending: String {
            String(localized: "github.completePending", defaultValue: "GitHub sent your request to the organization's owners. When an owner approves it, connect GitHub again.",
                   table: "GitHubConnection", bundle: .module)
        }
        static var refused: String {
            String(localized: "github.completeRefused", defaultValue: "GitHub isn't connected: this link expired or is for another sign-in. Connect GitHub again.",
                   table: "GitHubConnection", bundle: .module)
        }
        static var noAnswer: String {
            String(localized: "github.completeNoAnswer", defaultValue: "Couldn't reach cmux Cloud to finish connecting GitHub. Try again.",
                   table: "GitHubConnection", bundle: .module)
        }
    }

    /// Finishes `url` when it is this build's GitHub completion link (false for any other URL) and shows its answer
    /// on the key window: Connect GitHub runs this connection's connect, Retry finishes the same link again.
    @MainActor public func finishCompletion(_ url: URL, auth: CloudAuth) -> Bool {
        CloudGitHubCompletion.handle(url, auth: auth) { answer in
            guard let notice = CompletionNotice(answer), let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            let toast = CmuxToast(id: CompletionNotice.toastID, message: notice.message, action: CmuxToast.Action(title: notice.retryTitle),
                                  duration: .seconds(12), tone: notice.tone, oneWindow: true)
            CmuxToastCenter.shared.show(toast, in: window).onAction = { [weak self] in self?.retry(notice, url: url, auth: auth) }
        }
    }

    @MainActor private func retry(_ notice: CompletionNotice, url: URL, auth: CloudAuth) {
        guard notice.retry == .connect else { _ = finishCompletion(url, auth: auth); return }
        // task-owner: one connect per click; its page opens in the browser, a connect that cannot start says why.
        Task { [weak self] in
            guard let result = await self?.connectResult() else { return }
            let message = AgentPaneGitHubConnect(result).message
            guard !message.isEmpty, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            CmuxToastCenter.shared.show(CmuxToast(id: CompletionNotice.toastID, message: message, duration: .seconds(12), tone: .error, oneWindow: true), in: window)
        }
    }
}
