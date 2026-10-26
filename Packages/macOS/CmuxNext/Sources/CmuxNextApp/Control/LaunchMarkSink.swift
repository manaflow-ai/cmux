import CmuxNextLaunch
import CmuxNextProcessEnvironment
import Darwin

nonisolated extension LaunchMarkSink {
    /// Children (the daemon, terminals) must not inherit the variable: its
    /// descriptor number means nothing to them. Creates ``shared`` first, so
    /// the sink has read the descriptor. Runs in `CmuxNextApp.prepareLaunchEnvironment`.
    static func dropInheritedDescriptor(environmentGuard: ProcessEnvironmentGuard = .process) {
        _ = shared
        environmentGuard.write("LaunchMarkSink.dropInheritedDescriptor") {
            unsetenv(environmentKey)
        }
    }
}
