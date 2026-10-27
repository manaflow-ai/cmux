import CmuxNextCompat
import CmuxNextCrashReporting
import CmuxNextFeatures
import CmuxNextTrace

/// The last-hang bundles' inputs (p09-observability-125, ``LastHangHost``): the app's black box, its Rust log and
/// trace folders, its blocking-work lanes and the `lastHangBundle` feature.
extension AppServices: LastHangHost {
    var lastHangBlackBox: TraceBlackBox? { traceBlackBox?.blackBox }
    var lastHangRoots: RustDiagnosticsLog.Roots { .app(sessionsDirectory: RustDiagnosticsLog.Roots.ownerSessionsDirectory(stateDirectory: environment.daemonStateDirectory), session: environment.daemonSession, acpmuxHome: nil, bundleID: environment.launch.bundleID) }
    var lastHangWork: any MayBlockRunner { work }
    var capturesLastHangs: Bool { features.isEnabled(.lastHangBundle) }
}
