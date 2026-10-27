import Foundation

/// Builds an in-band install for pane-bound agent launchers. The remote helper
/// is bundled with the app; no provider settings or extra SSH connection are used.
struct RemoteTmuxAgentHookInstaller {
    static func installCommand(sessionTarget: String, payload: Data? = bundledPayload) -> String? {
        guard let payload, !sessionTarget.isEmpty,
              RemoteTmuxHost.controlModeLineSafeName(sessionTarget) != nil else { return nil }
        // A bare name that starts with `@` or `%` is a window or pane target to
        // tmux (#21595). The helper passes the same value to its own `-t` calls,
        // so it gets the exact target too; a `$id` is already exact.
        let target = RemoteTmuxHost.exactSessionTarget(sessionTarget) ?? sessionTarget
        let encoded = payload.base64EncodedString()
        let loader = "import base64,sys;exec(compile(base64.b64decode(sys.argv[3]),'<cmux-tmux-agent>','exec'))"
        let shell = ["python3", "-c", loader, "--install", target, encoded]
            .map(RemoteTmuxHost.shellSingleQuoted).joined(separator: " ")
        return "run-shell -b -t \(RemoteTmuxHost.shellSingleQuoted(target)) \(RemoteTmuxHost.shellSingleQuoted(shell))"
    }

    private static let bundledPayload: Data? = {
        guard let url = Bundle.main.url(forResource: "cmux-tmux-agent", withExtension: "py", subdirectory: "bin") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }()
}
