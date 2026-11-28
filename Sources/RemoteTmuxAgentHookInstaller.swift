import Foundation

/// Builds an in-band install for pane-bound agent launchers. The remote helper
/// is bundled with the app; no provider settings or extra SSH connection are used.
struct RemoteTmuxAgentHookInstaller {
    /// One `run-shell` that installs the helper once and configures every session in
    /// `sessionTargets`. The payload is about 17 KB, so callers batch sessions rather than
    /// sending a copy for each. Targets that cannot ride a control-mode line are skipped.
    static func installCommand(sessionTargets: [String], payload: Data? = bundledPayload) -> String? {
        let targets = sessionTargets.filter { !$0.isEmpty && RemoteTmuxHost.controlModeLineSafeName($0) != nil }
        guard let payload, let first = targets.first else { return nil }
        let encoded = payload.base64EncodedString()
        let loader = "import base64,sys;exec(compile(base64.b64decode(sys.argv[-1]),'<cmux-tmux-agent>','exec'))"
        let shell = (["python3", "-c", loader, "--install"] + targets + [encoded])
            .map(RemoteTmuxHost.shellSingleQuoted).joined(separator: " ")
        return "run-shell -b -t \(RemoteTmuxHost.shellSingleQuoted(first)) \(RemoteTmuxHost.shellSingleQuoted(shell))"
    }

    private static let bundledPayload: Data? = {
        guard let url = Bundle.main.url(forResource: "cmux-tmux-agent", withExtension: "py", subdirectory: "bin") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }()
}
