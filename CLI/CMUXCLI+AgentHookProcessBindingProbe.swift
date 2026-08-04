import Darwin
import Foundation

extension AgentPIDProcessIdentity {
    init?(agentTurnPID pid: Int?) {
        guard let pid,
              let generation =
                AgentTurnProcessGenerationReader.read(pid: pid) else {
            return nil
        }
        self.init(
            pid: pid_t(pid),
            startSeconds: generation.startSeconds,
            startMicroseconds: generation.startMicroseconds
        )
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
