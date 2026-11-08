public import CmuxNextCloud
import Foundation

extension CloudSignInEnroll {
    /// ``CloudSignInEnroll`` over the app's acpmux (`environment`; nil with no acpmux, as in a mock
    /// agent host): each request is one short ``AcpmuxPersonLine``, sent only when the daemon serves
    /// ``CloudSignInEnroll/capability``. The hub is the platform origin the app's `cmux machine add` mints
    /// on (`CMUX_PLATFORM_URL`), so both joins land on the same hub.
    public static func overAcpmux(auth: CloudAuth, buildTag: String?,
                                  environment: @escaping @MainActor () -> AcpmuxEnvironment?) -> CloudSignInEnroll {
        let hub = ProcessInfo.processInfo.environment["CMUX_PLATFORM_URL"]
        return CloudSignInEnroll(auth: auth, hub: hub, buildTag: buildTag) { method, params in
            // The deadline covers a join that holds acpmux's lock for a while, then the hub's answers.
            guard let environment = environment(),
                  let line = await AcpmuxPersonLine.open(environment, deadline: .seconds(90)) else { return nil }
            defer { line.close() }
            guard line.capabilities.contains(capability) else { return nil }
            return await line.call(method, params)
        }
    }
}
