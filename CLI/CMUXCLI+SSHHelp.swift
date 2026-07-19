import Foundation

extension CMUXCLI {
    static var sshCommandUsage: String {
        let help = String(localized: "cli.help.ssh", defaultValue: """
        Usage: cmux ssh <destination> [flags] [-- <remote-command-args>]

        Create a new workspace, mark it as remote-SSH, and start an SSH session in that workspace.
        cmux will also establish a local SSH proxy endpoint so browser traffic can egress from the remote host.

        Flags:
          --name <title>          Optional workspace title
          --port <n>              SSH port
          --identity <path>       SSH identity file path
          -A, --forward-agent     Forward the caller's SSH agent; also honors ForwardAgent yes from ssh_config
          -a, --no-forward-agent  Disable SSH agent forwarding for this workspace
          --ssh-option <opt>      Extra SSH -o option (repeatable)
          --window <id|ref|index> Target window for the managed workspace
          --no-focus              Create workspace without switching to it

        Example:
          cmux ssh dev@my-host
          cmux ssh dev@my-host --name "gpu-box" --port 2222 --identity ~/.ssh/id_ed25519
          cmux ssh dev@my-host --forward-agent
          cmux ssh dev@my-host --ssh-option UserKnownHostsFile=/dev/null --ssh-option StrictHostKeyChecking=no
        """)
        let moshHelp = String(
            localized: "cli.help.ssh.mosh",
            defaultValue: """
            Mosh terminal transport:
              --transport <ssh|mosh>  Interactive terminal transport (default: ssh)

            SSH continues to handle remote features; Mosh carries only the interactive
            terminal. If Mosh is missing locally or remotely, cmux reports it and uses SSH.

            Example:
              cmux ssh dev@my-host --transport mosh
            """
        )
        return "\(help)\n\n\(moshHelp)"
    }
}
