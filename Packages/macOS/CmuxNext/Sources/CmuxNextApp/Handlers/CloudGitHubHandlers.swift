import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemonService
import CmuxNextPages

/// Set Up GitHub on This Machine (`cmux cloud setup-github --target machine:<id>`): the cmux GitHub
/// App's helper by default (CloudGitHubSetup), the machine's own sign-in as the fallback, over
/// ``CloudHandlers``' machine resolution, runs and results (its own type: CloudHandlers is at the
/// god-type limit).
enum CloudGitHubHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud
        CloudHandlers.bind("cloudSetupGitHub", registry, reason: reason) { invocation in
            // A CLI, MCP or script run names its machine (#23155); a person's may mean the one they see.
            let session = try CloudHandlers.machine(invocation, context)
            guard session.machine.allows(.exec) else { throw ActionFailure(message: CloudStrings.execUnavailable(session.machineID)) }
            // A nested perform inside a CLI run is built with the user origin: the enclosing
            // run's scope decides too, so only `--focus` (or a person) opens the browser.
            let opensBrowser = invocation.allowsViewChange && ActionRunScope.viewChangeAllowed()
            // The cmux GitHub App by default; the machine's own sign-in only when the App, the team's
            // connection or the machine's Cloud agent is not there.
            let setUp: @MainActor (CloudGitHubSetup.GitIdentity, CloudGitHubApp) async throws -> CloudGitHubSetup.Outcome = { identity, app in
                try await CloudGitHubSetup.run(identity, app: app == .ready, machine: session.machineID, on: cloud.machineAPI)
            }
            guard CloudHandlers.origin(of: invocation) == .user else {
                // The caller is the confirmation: it named the machine. It reads the code from the
                // result; the browser opens only when the run asked for focus.
                return CloudHandlers.result("set up GitHub on Cloud machine", context) {
                    let identity = try CloudGitHubSetup.validated(await CloudGitHubSetup.localIdentity())
                    let app = await cloud.gitHubApp()
                    let outcome = try await setUp(identity, app)
                    if opensBrowser, outcome.deviceCode != nil { openVerificationPage() }
                    return CloudGitHubSetup.fields(outcome, identity: identity, fallback: CloudGitHubSetup.fallback(app, outcome))
                }
            }
            // The person's click is the go-ahead: no sheet. A team without the cmux GitHub App gets its
            // installation page and a toast to Set Up again once it is done; else the App, or the machine's own sign-in.
            CloudHandlers.runTracked("set up GitHub on Cloud machine", context) {
                let identity = try CloudGitHubSetup.validated(await CloudGitHubSetup.localIdentity())
                var app = await cloud.gitHubApp()
                if app == .notConnected {
                    switch AgentPaneGitHubConnect(await context.services.accounts.github.connectResult()) {
                    case .opened: // the installation page is open in the browser; Set Up again once it is done
                        return CloudPresenter.show(CloudStrings.gitHubSetupTitle, CloudStrings.gitHubConnectBody, in: CloudHandlers.window(context))
                    case .alreadyConnected: app = .ready // connected meanwhile: set up through the App now
                    case .failed(let message): return CloudPresenter.show(CloudStrings.gitHubSetupTitle, message, failed: true, in: CloudHandlers.window(context))
                    }
                }
                let outcome = try await setUp(identity, app)
                // The person clicked Set Up: one browser page, with the code on the clipboard to paste.
                if let code = outcome.deviceCode {
                    CloudPresenter.copy(code)
                    openVerificationPage()
                }
                CloudPresenter.show(CloudStrings.gitHubSetupTitle, CloudGitHubSetup.summary(outcome, fallback: CloudGitHubSetup.fallback(app, outcome)),
                                    in: CloudHandlers.window(context))
            }
        }
    }

    /// GitHub's device page (a constant, never a URL the machine printed), in a cmux tab (`browser.openSignInPagesInCmux`).
    private static func openVerificationPage() {
        guard let url = URL(string: CloudGitHubSetup.verificationURI) else { return }
        LinkRouter.shared.open(url)
    }
}
