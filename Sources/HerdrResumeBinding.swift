import CmuxHerdrResume
import Foundation

extension HerdrResumeInvocation {
    /// The process-detected resume binding that reattaches this herdr client
    /// after a relaunch. It resumes automatically, like a tmux attach, because
    /// the herdr server and its agents outlive cmux.
    func resumeBinding(capturedAt: TimeInterval) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: sessionName.map { "herdr \($0)" } ?? "herdr",
            kind: "herdr",
            command: shellCommand,
            cwd: workingDirectory,
            checkpointId: sessionName,
            source: "process-detected",
            environment: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: nil,
                executablePath: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: nil,
                capturedAt: capturedAt,
                source: "process-detected"
            ),
            autoResume: true,
            updatedAt: capturedAt
        )
    }
}
