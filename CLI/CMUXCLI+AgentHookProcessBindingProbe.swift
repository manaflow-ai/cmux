import Darwin
import Foundation

extension AgentPIDProcessIdentity {
    init?(agentTurnPID pid: Int?) {
        guard let pid,
              pid > 0,
              pid <= Int(Int32.max),
              let generation = AgentPIDProcessIdentity(pid: pid_t(pid)) else {
            return nil
        }
        self = generation
    }

    var liveness: AgentTurnProcessLiveness {
        AgentTurnProcessLiveness.observe(
            pid: Int(pid),
            expectedStartSeconds: startSeconds,
            expectedStartMicroseconds: startMicroseconds
        )
    }
}

extension CMUXCLI {
    enum AgentHookProcessBindingProbe {
        case notAttempted
        case unsupported
        case failed
        case resolved(CallerTerminalBinding)
    }
}
