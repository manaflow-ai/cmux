import CmuxNextControl
import CmuxNextProcessEnvironment
import Darwin

extension LaunchMarkSink {
    /// Children (the daemon, terminals) must not inherit the variables: the
    /// bench's descriptor number or FIFO means nothing to them. Creates ``shared`` first, so
    /// the sink has read the descriptor. Runs in `CmuxNextApp.prepareLaunchEnvironment`.
    static func dropInheritedDescriptor(environmentGuard: ProcessEnvironmentGuard = .process) {
        _ = shared
        environmentGuard.write("LaunchMarkSink.dropInheritedDescriptor") {
            for key in [environmentKey, pathKey] { unsetenv(key) } // neither means anything to a child
        }
    }
}
