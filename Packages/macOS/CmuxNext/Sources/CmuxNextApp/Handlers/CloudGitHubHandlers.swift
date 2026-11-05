import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
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
                let ran = try await cloud.api.exec(session.machineID, command: CloudGitHubSetup.command(identity, app: app == .ready),
                                                   timeoutMs: CloudGitHubSetup.timeoutMs)
                return CloudGitHubSetup.parse(exitCode: ran.exitCode, stdout: ran.stdout)
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
            CloudHandlers.runTracked("set up GitHub on Cloud machine", context) {
                let identity = try CloudGitHubSetup.validated(await CloudGitHubSetup.localIdentity())
                let app = await cloud.gitHubApp()
                let go = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                    CloudPresenter.confirm(CloudStrings.gitHubConfirmTitle(session.machine.title), confirmBody(identity, app: app),
                                           button: CloudStrings.gitHubSetUp, identifier: "cmux.dialog.cloud.setupGitHub",
                                           in: CloudHandlers.window(context)) { done.resume(returning: $0) }
                }
                guard go else { return }
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

    /// What Set Up will do: the App's helper, else the machine's own sign-in with the reason first.
    static func confirmBody(_ identity: CloudGitHubSetup.GitIdentity, app: CloudGitHubApp) -> String {
        let named = identity.name != nil || identity.email != nil
        let name = identity.name ?? "—", email = identity.email ?? "—"
        guard app != .ready else {
            return named ? CloudStrings.gitHubAppConfirmBody(name: name, email: email) : CloudStrings.gitHubAppConfirmNoIdentity
        }
        let signIn = named ? CloudStrings.gitHubConfirmBody(name: name, email: email) : CloudStrings.gitHubConfirmNoIdentity
        let reason = CloudGitHubSetup.reason(app).map(CloudStrings.gitHubFallback)
        return [reason, signIn].compactMap { $0 }.joined(separator: " ")
    }

    /// GitHub's device page (a constant, never a URL the machine printed), in a cmux tab (`browser.openSignInPagesInCmux`).
    private static func openVerificationPage() {
        guard let url = URL(string: CloudGitHubSetup.verificationURI) else { return }
        LinkRouter.shared.open(url)
    }
}
