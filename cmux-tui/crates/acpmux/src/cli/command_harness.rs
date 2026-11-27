//! The `acpmux harness` argument grammar (`HarnessCmd`, its `codex-runtime` and `secret`
//! subcommands), split from `command.rs`.

use clap::Subcommand;
use std::path::PathBuf;

// Parsed once per command line; boxing a variant would only reshape clap's derive.
#[allow(clippy::large_enum_variant)]
#[derive(Subcommand)]
pub enum HarnessCmd {
    /// Install a coding agent's CLI through its vendor's own installer (claude: Claude Code's
    /// official installer; codex: the pinned official Codex release), then reload the daemon.
    /// Runs only when asked; with --json each step is a JSON line, the last one the result.
    Install {
        /// claude or codex.
        id: String,
    },
    /// Install or inspect cmux's opt-in managed Codex runtime.
    CodexRuntime {
        #[command(subcommand)]
        action: CodexRuntimeCmd,
    },
    /// Every harness with its kind, source file and problems.
    #[command(alias = "ls")]
    List {
        /// Also list the folder profiles in DIR/.cmux/harnesses with their state.
        #[arg(long)]
        folder: Option<PathBuf>,
    },
    /// Write a new profile file into ~/.config/cmux-next/harnesses and check it.
    #[command(after_help = crate::cli::harness::add_help())]
    Add {
        /// Profile id (file name); default: the example's id or the command's name.
        id: Option<String>,
        /// The program to run: a name on PATH or an absolute path.
        #[arg(long)]
        command: Option<String>,
        /// acp (Agent Client Protocol over stdio) or terminal (a CLI/TUI without ACP).
        #[arg(long, default_value = "acp")]
        protocol: String,
        /// Start from a shipped example: claude, codex, opencode, cursor, pi, gemini,
        /// antigravity, aider, muse, muse-terminal, unii, hermes, openclaw, or your own
        /// model endpoint: anthropic-endpoint, openai-endpoint (with --base-url, --model).
        #[arg(long)]
        example: Option<String>,
        /// anthropic-endpoint / openai-endpoint: the endpoint's base URL (https; http only
        /// to localhost or 127.0.0.1).
        #[arg(long)]
        base_url: Option<String>,
        /// anthropic-endpoint / openai-endpoint: a model id the endpoint serves; repeat it or
        /// separate ids with commas for several (the first is the default). '*' adds every
        /// model the endpoint lists at <base URL>/models.
        #[arg(long)]
        model: Vec<String>,
        /// anthropic-endpoint / openai-endpoint: a Keychain item of your own that holds the key
        /// (`service` or `service/account`; never cmux's own `cmux-harness` items).
        #[arg(long, conflicts_with = "key")]
        keychain_item: Option<String>,
        /// anthropic-endpoint / openai-endpoint: read the key (a hidden prompt, or stdin) and
        /// store it in the Keychain for this endpoint only. Never on the command line.
        #[arg(long)]
        key: bool,
        /// anthropic-endpoint / openai-endpoint: the name the model picker shows.
        #[arg(long)]
        name: Option<String>,
        /// An argument the harness starts with, after the profile's own; repeat it for
        /// several (`--arg=--verbose` for one that starts with a dash).
        #[arg(long = "arg", value_name = "ARG", allow_hyphen_values = true)]
        args: Vec<String>,
        /// KEY=VALUE in the harness's environment; repeat it for several. Never a secret: a
        /// key or token goes in the Keychain with `cmux harness secret set ID KEY`.
        #[arg(long = "env", value_name = "KEY=VALUE")]
        env: Vec<String>,
        /// The agent's home folder: CLAUDE_CONFIG_DIR for Claude Code, CODEX_HOME for Codex.
        #[arg(long, value_name = "DIR")]
        home: Option<String>,
        /// Replace an existing file.
        #[arg(long)]
        force: bool,
        /// ID is an ACP Registry agent (`cmux harness registry`): write a
        /// profile that starts it at the registry's pinned version (its
        /// installed program, else npx, else uvx).
        #[arg(long, conflicts_with_all = ["command", "example"])]
        registry: bool,
        /// The icon cmux shows for it: one emoji, an SF Symbol name (hammer.fill), an agent
        /// mark (claude, goose, ...) or an .svg/.png file. Default: the mark of the agent its
        /// command runs, else a monogram.
        #[arg(long)]
        icon: Option<String>,
    },
    /// Show or set the icon cmux shows for one of your harnesses: one emoji, an SF Symbol
    /// name (hammer.fill), an agent mark (claude, goose, ...) or an .svg/.png file (copied
    /// next to the profile). With no VALUE, prints the icon cmux shows now and why.
    Icon {
        id: String,
        value: Option<String>,
        /// Remove the icon line: cmux picks the icon again.
        #[arg(long, conflicts_with = "value")]
        clear: bool,
    },
    /// Sign in to a harness with its own ACP sign-in (or `claude auth login`
    /// for Claude Code). `--status` checks it; `--list` shows the methods.
    Login {
        id: String,
        /// The sign-in method id (default: the harness's first browser or terminal sign-in).
        #[arg(long)]
        method: Option<String>,
        /// Show the sign-in methods and whether the harness is signed in.
        #[arg(long)]
        list: bool,
        /// Only check whether the harness is signed in.
        #[arg(long)]
        status: bool,
    },
    /// The ACP Registry's agents and how each can start here.
    Registry {
        /// Fetch the registry now instead of reading the cached copy.
        #[arg(long)]
        refresh: bool,
    },
    /// Start the harness in a temp folder, run the ACP handshake and one
    /// prompt, and print each step with an exact fix. Never prints env values.
    /// An id that is no catalog harness is looked up as a folder profile
    /// (DIR/.cmux/harnesses/ID.toml in --folder or the current folder, or
    /// their nearest parent); an enabled one starts inside its folder.
    Doctor {
        id: String,
        /// Where to look for a folder profile (default: the current folder).
        #[arg(long)]
        folder: Option<PathBuf>,
        /// Stop after session/new: send no prompt (no model call).
        #[arg(long)]
        no_prompt: bool,
        /// Seconds each step may wait for the harness.
        #[arg(long, default_value_t = 120)]
        timeout: u64,
    },
    /// Allow a folder profile (DIR/.cmux/harnesses/ID.toml) in chats inside
    /// DIR: shows the command and env, then asks. The folder must be trusted.
    Enable {
        id: String,
        #[arg(long)]
        folder: PathBuf,
        /// Confirm without the prompt (needed without a terminal).
        #[arg(long)]
        yes: bool,
    },
    /// Withdraw a folder profile's confirmation.
    Disable {
        id: String,
        #[arg(long)]
        folder: PathBuf,
    },
    /// Run a protocol = "terminal" harness (a CLI/TUI without ACP) in this
    /// terminal with its profile env; `--tab` (cmux) opens it in a new tab.
    Run {
        id: String,
        /// The folder to run in (default: the current folder).
        #[arg(long)]
        cwd: Option<PathBuf>,
        /// The model for `${model}` (default: the profile's).
        #[arg(long)]
        model: Option<String>,
        /// Open a new tab in the current pane (cmux only).
        #[arg(long)]
        tab: bool,
    },
    /// Secrets for harness env keys, kept in the system secret store.
    #[command(subcommand)]
    Secret(SecretCmd),
    /// Tell the running daemon to read the profile files again.
    Reload,
    /// Print the guide an agent follows to integrate a harness (schema,
    /// doctor loop, examples, security rules).
    Guide,
    /// Move a profile file from your harness folder to a backup
    /// (~/.acpmux/harness-backups); `restore` brings it back, its Keychain key included.
    Remove {
        id: String,
        /// Also delete the endpoint's own Keychain items (`cmux-harness/<id>/...`); a later
        /// `restore` then needs `cmux harness secret set` again.
        #[arg(long)]
        forget_key: bool,
    },
    /// Move a backup that `remove` made back into your harness folder.
    Restore { backup: String },
}

#[derive(Subcommand)]
pub enum CodexRuntimeCmd {
    /// Download and verify the pinned official Codex release.
    Install,
    /// Print the managed runtime status.
    Status,
}

#[derive(Subcommand)]
pub enum SecretCmd {
    /// Store a value for ID's env KEY (Keychain on macOS, secret-tool
    /// elsewhere) and write `KEY = { keychain = "cmux-harness/ID/KEY" }` into
    /// the profile file. Reads a hidden prompt, or stdin; never prints it.
    Set { id: String, key: String },
}
