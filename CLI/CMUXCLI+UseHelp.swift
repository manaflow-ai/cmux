extension CMUXCLI {
    static let cmuxUseCommandHelp = """
    Usage: cmux use <owner/repo|github-url> [--command <cmd>] [--no-run]

    Clone or update a cmux extension from GitHub, install it, then open a
    new workspace for it. Extension checkouts live under ~/.cmux so legacy
    shell scripts do not break on macOS paths with spaces. Repos with
    cmux.extension.json are installed as versioned extensions. Repos
    without a manifest get a generated compatibility manifest from
    package.json, README.md, and common setup/launch scripts. Manifests
    can declare install.path and install.command for repos that must live
    somewhere specific, such as another tool's config directory.

    Repository formats:
      owner/repo
      https://github.com/owner/repo
      git@github.com:owner/repo.git

    Detection order:
      cmux.extension.json install plus launch/command/main
      cmux-extension.json install plus launch/command/main
      generated compatibility manifest
      launch.sh, use.sh, start.sh, run.sh
      package.json scripts: use, cmux, start, dev
      Makefile targets: start, run, use

    Flags:
      --command <cmd>  Run this command instead of the detected command
      --no-run         Only clone/update and open the workspace

    Examples:
      cmux use stoneHee99/cmux-spotify
      cmux use https://github.com/stoneHee99/cmux-spotify
      cmux use owner/repo --command "./install.sh"
    """
}
