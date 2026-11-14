public import CmuxNextDaemon
import CmuxNextWakeups
import Dispatch
import Darwin
import Foundation

private struct CaptureRemoteProcessStamp: Sendable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    init?(value: JSONValue?) {
        guard case .object(let fields) = value,
              let pid = fields["pid"].flatMap(Self.int32), pid > 1,
              let seconds = fields["start_sec"].flatMap(Self.uint64),
              let micros = fields["start_usec"].flatMap(Self.uint64), micros < 1_000_000 else { return nil }
        self.pid = pid; startSeconds = seconds; startMicroseconds = micros
    }

    private static func int32(_ value: JSONValue) -> pid_t? {
        guard let number = value.doubleValue else { return nil }
        return pid_t(exactly: number)
    }

    private static func uint64(_ value: JSONValue) -> UInt64? {
        guard let number = value.doubleValue else { return nil }
        return UInt64(exactly: number)
    }

    var hasExited: Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            // EPERM and other inspection failures prove nothing about exit.
            return errno == ESRCH
        }
        return info.pbi_start_tvsec != startSeconds || info.pbi_start_tvusec != startMicroseconds
    }

}

/// Exit events and a deadline for the exact stamped processes; inspection
/// errors remain unverified. The producer has already fenced and reaped writers.
@MainActor
private final class CaptureRemoteExitWatch {
    let stamps: [CaptureRemoteProcessStamp]
    private var sources: [any DispatchSourceProcess] = []
    private let deadline = DemandTimer(owner: "capture.remote.exit")
    private var continuation: CheckedContinuation<Bool, Never>?

    init(stamps: [CaptureRemoteProcessStamp]) { self.stamps = stamps }

    func observeExit() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for stamp in stamps {
                let source = DispatchSource.makeProcessSource(identifier: stamp.pid, eventMask: .exit, queue: .main)
                source.setEventHandler { [weak self] in
                    // task-owner: a single main-actor hop for an owned exit event.
                    MainDelivery().run { self?.check() }
                }
                sources.append(source)
                source.resume()
            }
            deadline.schedule(after: .seconds(20)) { [weak self] in
                // task-owner: one bounded cleanup deadline.
                MainDelivery().run { self?.finish(false) }
            }
            check()
        }
    }

    private func check() {
        if stamps.allSatisfy(\.hasExited) { finish(true) }
    }

    private func finish(_ exited: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        deadline.cancel()
        for source in sources { source.cancel() }
        sources.removeAll()
        continuation.resume(returning: exited)
    }
}

extension CmuxRemoteService {
    /// The protected capture facade. The host response cannot attest process
    /// exit; cleanup drains admission, disables both workers, then this app
    /// observes the stamped host before publishing success. The producer owns
    /// every descendant lifetime: worker_quiescent attests reaping all children
    /// with admission frozen, so the app never discovers children by scanning.
    public func capture(phase: String, leaseID: String, bundleID: String, privateRoot: String) async -> JSONValue {
        guard phase == "prepare" || phase == "cleanup" else { return Self.captureFailure(code: "invalid_request") }
        let method = phase == "prepare" ? "capture.prepare" : "capture.cleanup"
        let request: JSONValue = .object(["lease_id": .string(leaseID), "bundle_id": .string(bundleID),
                                          "private_root": .string(privateRoot)])
        let raw: JSONValue
        let grantedPID: Int32
        do {
            grantedPID = try await appGrant(refresh: true).hostPID
            raw = try await call(method, request)
        } catch { return Self.captureFailure(code: "remote_unavailable") }
        guard raw["lease_bound"]?.boolValue == true,
              raw["verified_absent"]?.boolValue == true,
              raw["worker_quiescent"]?.boolValue == true,
              let host = CaptureRemoteProcessStamp(value: raw["host_stamp"]), host.pid == grantedPID else {
            return Self.strictCaptureResult(raw)
        }
        _ = try? await call("drain")
        await apply(computerUse: false, screenSharing: false, headless: true)
        return Self.strictCaptureResult(raw, exited: await Self.waitForExit([host]))
    }

    private static func waitForExit(_ stamps: [CaptureRemoteProcessStamp]) async -> Bool {
        await CaptureRemoteExitWatch(stamps: stamps).observeExit()
    }

    static func strictCaptureResult(_ raw: JSONValue, exited: Bool = false) -> JSONValue {
        let code = raw["code"]?.stringValue ?? "remote_invalid_result"
        let workerStarted = raw["worker_started"]?.boolValue ?? false
        let leaseBound = raw["lease_bound"]?.boolValue ?? false
        let identityRemoved = raw["identity_removed"]?.doubleValue ?? 0
        let relaysRemoved = raw["relays_removed"]?.doubleValue ?? 0
        let verifiedAbsent = raw["verified_absent"]?.boolValue ?? false
        let workerQuiescent = raw["worker_quiescent"]?.boolValue ?? false
        let terminal = leaseBound && exited && verifiedAbsent && workerQuiescent
        let publicCode = terminal && code == "remote_exit_unverified" ? "ok" : code
        let noRemote = code == "no_remote_started" && raw["ok"]?.boolValue == true && terminal
        return .object(["ok": .bool(noRemote || (terminal && code == "remote_exit_unverified")),
                        "code": .string(publicCode), "lease_bound": .bool(leaseBound),
                        "worker_started": .bool(workerStarted), "identity_removed": .number(identityRemoved),
                        "relays_removed": .number(relaysRemoved), "verified_absent": .bool(verifiedAbsent),
                        "worker_quiescent": .bool(workerQuiescent),
                        "worker_pid_exited": .bool(exited),
                        "descendants_exited": .bool(exited)])
    }

    private static func captureFailure(code: String) -> JSONValue {
        .object(["ok": .bool(false), "code": .string(code), "lease_bound": .bool(false),
                 "worker_started": .bool(false), "identity_removed": .number(0), "relays_removed": .number(0),
                 "verified_absent": .bool(false), "worker_quiescent": .bool(false),
                 "worker_pid_exited": .bool(false), "descendants_exited": .bool(false)])
    }
}
