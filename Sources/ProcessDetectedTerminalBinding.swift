import Foundation

/// Picks the process-detected resume binding for one foreground terminal
/// process: a tmux client, then a herdr client, then an interactive SSH
/// session. A process that matches none of them yields no binding.
enum ProcessDetectedTerminalBinding {
    static func binding(
        processName: String,
        processPath: String?,
        processArguments: CmuxTopProcessArguments,
        capturedAt: TimeInterval
    ) -> SurfaceResumeBindingSnapshot? {
        let arguments = processArguments.arguments
        let environment = processArguments.environment
        // A process inside a herdr pane carries the CMUX_* scope of the
        // surface that first started the herdr server, but it runs on herdr's
        // own PTY. Letting it through would bind an `ssh` or `tmux` from deep
        // inside herdr to that surface, where it could outrank the surface's
        // real foreground herdr client.
        if HerdrResumeParser.isInsideHerdrPane(environment: environment) {
            return nil
        }
        if let tmuxBinding = TmuxResumeParser.binding(
            processName: processName,
            processPath: processPath,
            arguments: arguments,
            environment: environment,
            capturedAt: capturedAt
        ) {
            return tmuxBinding
        }
        if let herdrBinding = HerdrResumeParser.binding(
            arguments: arguments,
            environment: environment,
            capturedAt: capturedAt
        ) {
            return herdrBinding
        }
        return TerminalSSHSessionDetector.resumeBinding(
            processName: processName,
            processPath: processPath,
            arguments: arguments,
            environment: environment,
            capturedAt: capturedAt
        )
    }
}
