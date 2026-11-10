public import CmuxNextCloud
import Foundation

extension CloudSignInEnroll {
    /// ``CloudSignInEnroll`` over the app's acpmux (`environment`; nil with no acpmux, as in a mock
    /// agent host): each request is one short ``AcpmuxPersonLine``, sent only when it proved the person
    /// and the daemon serves ``CloudSignInEnroll/capability``. The hub is the platform origin the app selected
    /// (`CloudConfiguration.relayAPIBaseURL`), the backend the person signed in to. `windows`: the app's
    /// connection to acpmux's chat index, whose return (a restarted daemon answering) sends a sign-out's
    /// unanswered leave again. A sign-out's account is recorded first with the bundled acpmux CLI, which
    /// needs no daemon.
    public static func overAcpmux(auth: CloudAuth, buildTag: String?, windows: AcpmuxChatWindows?,
                                  environment: @escaping @MainActor () -> AcpmuxEnvironment?) -> CloudSignInEnroll {
        let hub = auth.configuration.relayAPIBaseURL().absoluteString
        let enroll = CloudSignInEnroll(auth: auth, hub: hub, buildTag: buildTag, recordLeave: { userId in
            // `acpmux machine leave-intent`: the CLI writes it in the app's acpmux home, daemon or not.
            guard let environment = environment() else { return false }
            var variables = ProcessInfo.processInfo.environment
            variables.merge(environment.childEnvironment) { $1 }
            let command = AcpmuxPeerUpdateCommand(executable: environment.executable, environment: variables,
                                                  deadline: .seconds(45))
            return await command.run(["--json", "machine", "leave-intent", "--user-id", userId]).status == 0
        }) { method, params in
            // The deadline covers a join that holds acpmux's lock for a while, then the hub's answers.
            guard let environment = environment(),
                  let line = await AcpmuxPersonLine.open(environment, deadline: .seconds(90)) else { return nil }
            defer { line.close() }
            // Only a line that proved the person may enroll or leave; the daemon refuses any other.
            guard line.isPerson, line.capabilities.contains(capability) else { return nil }
            return await line.call(method, params)
        }
        windows?.followAvailability(enroll) { [weak enroll] in enroll?.acpmuxReturned() }
        return enroll
    }
}
