public import CmuxNextCloud
import Foundation

extension CloudSignInEnroll {
    /// ``CloudSignInEnroll`` over the app's acpmux (`environment`; nil with no acpmux, as in a mock
    /// agent host): each request is one short ``AcpmuxPersonLine``, sent only when it proved the person
    /// and the daemon serves ``CloudSignInEnroll/capability``. The hub is the platform origin the app selected
    /// (`CloudConfiguration.relayAPIBaseURL`), the backend the person signed in to. `windows`: the app's
    /// connection to acpmux's chat index, whose return (a restarted daemon answering) sends a sign-out's
    /// unanswered leave again.
    public static func overAcpmux(auth: CloudAuth, buildTag: String?, windows: AcpmuxChatWindows?,
                                  environment: @escaping @MainActor () -> AcpmuxEnvironment?) -> CloudSignInEnroll {
        let hub = auth.configuration.relayAPIBaseURL().absoluteString
        let enroll = CloudSignInEnroll(auth: auth, hub: hub, buildTag: buildTag) { method, params in
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
