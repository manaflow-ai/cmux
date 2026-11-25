import Foundation

struct CaptureLeaseResult: Sendable {
    var code: String
    var leaseBound = false
    var workerStarted = false
    var identities = 0
    var relays = 0
    var verifiedAbsent = false
    var quiescent = false

    var fields: [String: Any] {
        ["ok": code == "no_remote_started", "code": code, "lease_bound": leaseBound,
         "worker_started": workerStarted, "identity_removed": identities, "relays_removed": relays,
         "verified_absent": verifiedAbsent, "worker_quiescent": quiescent,
         // A running host cannot attest its own exit. The authenticated app observes its stamp after drain.
         "worker_pid_exited": false, "descendants_exited": false]
    }
}
