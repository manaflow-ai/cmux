import Darwin
import Foundation

extension CMUXCLI {
    enum AgentHookProcessBindingProbe {
        case notAttempted
        case unsupported
        case failed
        case resolved(pid: Int, binding: CallerTerminalBinding)
    }
}
