import CmuxNextCloud
public import CmuxNextDaemon
import Foundation

/// DEV-only control methods for the lease-bound auth persistence proof.
public struct CaptureAuthControl: Sendable {
    public init() {}

    public func register(on router: ControlRouter?,
                         remote: @escaping @MainActor @Sendable (String, String, String, String) async -> JSONValue,
                         auth: @escaping @MainActor @Sendable () -> CloudAuth?) {
        #if DEBUG || CMUX_BENCH_HOOKS
        router?.register([
            .async("debug.cloud.capture_prepare") { call in
                await run(call, phase: .prepare, auth: auth)
            },
            .async("debug.cloud.capture_cleanup") { call in
                await run(call, phase: .cleanup, auth: auth)
            },
        ])
        router?.register(["prepare", "resume", "cleanup"].map { phase in
            .async("debug.remote.capture_" + phase) { call in
                guard call.params.count == 3,
                      let lease = call.params["lease_id"]?.stringValue,
                      let bundle = call.params["bundle_id"]?.stringValue,
                      let root = call.params["private_root"]?.stringValue else {
                    return .object(["ok": .bool(false), "code": .string("invalid_request"),
                                    "lease_bound": .bool(false), "worker_started": .bool(false),
                                    "identity_removed": .number(0), "relays_removed": .number(0),
                                    "verified_absent": .bool(false), "worker_quiescent": .bool(false),
                                    "worker_pid_exited": .bool(false), "descendants_exited": .bool(false)])
                }
                return await remote(phase, lease, bundle, root)
            }.withDeadline(.fixed(.seconds(80)))
        })
        #endif
    }

    #if DEBUG || CMUX_BENCH_HOOKS
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
    #endif
}
