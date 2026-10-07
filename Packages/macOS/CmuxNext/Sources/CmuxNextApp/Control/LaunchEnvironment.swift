import CmuxNextControl
import CmuxNextProcessEnvironment
import CmuxNextTerminal

/// This process's environment writes, in launch order, then the freeze.
enum LaunchEnvironment {
    static func prepare(environmentGuard: ProcessEnvironmentGuard = .process) {
        environmentGuard.freeze()
        LaunchIdentity.stripInheritedEnvironment()
        GhosttyRuntime.prepareProcessEnvironment()
        _ = LaunchMarkSink.shared
    }
}
