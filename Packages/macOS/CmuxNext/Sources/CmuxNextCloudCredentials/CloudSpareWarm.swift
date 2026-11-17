public import CmuxNextCloud
public import Foundation

/// Leo, Cloud V0 item 1: "A chat starts in a few seconds: ready spare". On the person's intent (the composer picks Cloud,
/// or the app comes to the front signed in) Rust warms their paused spare (`cmux link start-chat warm-spare`, which also
/// picks the team and how often). No login goes with it: a Cloud machine's agents reach models through its edge, so this
/// Mac copies none. A warm Rust answers with a copy target is reported finished at once, so nothing waits on a copy.
@MainActor public final class CloudSpareWarm {
    let auth: CloudAuth, cli: CloudMoveCLI, platform: URL, installIdentity: MacInstallIdentity

    public init(auth: CloudAuth, cli: CloudMoveCLI, platform: URL, installIdentity: MacInstallIdentity) {
        self.auth = auth; self.cli = cli; self.platform = platform; self.installIdentity = installIdentity
    }

    /// Fires the warm; the caller never awaits it. Rust decides the team and the throttle.
    public func start() {
        guard let userID = auth.user?.id else { return }
        // task-owner: none; one bounded warm, its calls' own timeouts end it, and Rust's lock and throttle answer repeats.
        Task { @MainActor [self] in
            guard let token = try? await auth.tokens().access, let install = try? await installIdentity.installToken(),
                  let copy = await cli.startChatWarmSpare(platform: platform, account: userID, access: token, install: install) else { return }
            _ = await cli.startChatWarmSpare(platform: platform, account: userID, access: token, install: install, end: .finished(copy.machineID))
        }
    }
}
