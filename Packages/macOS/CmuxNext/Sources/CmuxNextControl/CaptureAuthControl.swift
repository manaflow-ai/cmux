import CmuxNextCloud
import Foundation

#if DEBUG || CMUX_BENCH_HOOKS
/// DEV-only control methods for the lease-bound auth persistence proof.
public struct CaptureAuthControl: Sendable {
    public init() {}

    public func register(on router: ControlRouter?, auth: @escaping @MainActor @Sendable () -> CloudAuth?) {
        router?.register([
            .async("debug.cloud.capture_prepare") { call in
                await run(call, phase: .prepare, auth: auth)
            },
            .async("debug.cloud.capture_cleanup") { call in
                await run(call, phase: .cleanup, auth: auth)
            },
        ])
    }

    private func run(_ call: ControlCall, phase: CaptureAuthCleanupPhase,
                     auth: @escaping @MainActor @Sendable () -> CloudAuth?) async -> JSONValue {
        guard let leaseID = call.params["lease_id"]?.stringValue,
              let bundleID = call.params["bundle_id"]?.stringValue,
              let auth = await MainActor.run(body: auth) else {
            return json(.failure(.invalidLease))
        }
        return json(await auth.captureAuthCleanup(phase: phase, leaseID: leaseID,
                                                  requestedBundleIdentifier: bundleID))
    }

    private func json(_ result: CaptureAuthCleanupResult) -> JSONValue {
        var encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(result),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return .null }
        return JSONValue(foundation: object) ?? .null
    }
}
#endif
