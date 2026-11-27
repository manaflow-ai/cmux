//! `acpmux daemon …` help examples (see `help_examples/mod.rs`).

use super::Example;

pub(super) const EXAMPLES: &[(&str, &[Example])] = &[
    (
        "daemon",
        &[
            ("Show the daemon's status and web URL", "acpmux daemon status"),
            ("Start the daemon unless one runs", "acpmux daemon start"),
            ("Restart the daemon, keeping sessions", "acpmux daemon restart"),
        ],
    ),
    (
        "daemon run",
        &[
            ("Run the daemon in the foreground", "acpmux daemon run"),
            ("Run it with debug logs", "acpmux daemon run --log debug"),
            (
                "Also serve WebSocket clients on a local port",
                "acpmux daemon run --listen 127.0.0.1:47811",
            ),
        ],
    ),
    (
        "daemon status",
        &[
            ("Show the daemon's status, hosts and web URL", "acpmux daemon status"),
            ("Print the web URL with its bearer token", "acpmux daemon status --show-token"),
        ],
    ),
    (
        "daemon stats",
        &[
            ("The busiest callers over the last minute", "acpmux daemon stats"),
            (
                "The busiest methods over the last 10 minutes",
                "acpmux daemon stats --by method --since 10m",
            ),
            ("Every caller's counts as JSON", "acpmux --json daemon stats --top 100"),
        ],
    ),
    (
        "daemon start",
        &[
            ("Start the daemon and wait until it accepts clients", "acpmux daemon start"),
            ("Start it and print its status as JSON", "acpmux daemon start --json"),
        ],
    ),
    (
        "daemon prune",
        &[
            (
                "List every daemon home, what a prune would clear and why the rest stay",
                "acpmux daemon prune",
            ),
            ("Clear the records dead daemons left", "acpmux daemon prune --apply"),
            ("The same list as JSON", "acpmux --json daemon prune"),
        ],
    ),
    (
        "daemon restart",
        &[("Restart the daemon; hosted sessions resume after", "acpmux daemon restart")],
    ),
    (
        "daemon service",
        &[
            ("Keep the daemon running across logouts and reboots", "acpmux daemon service install"),
            ("Whether the service is installed and running", "acpmux daemon service status"),
        ],
    ),
    (
        "daemon service install",
        &[
            (
                "Install the LaunchAgent or systemd unit and start the daemon under it",
                "acpmux daemon service install",
            ),
            ("The same, as JSON (manager, path, state)", "acpmux --json daemon service install"),
        ],
    ),
    (
        "daemon service uninstall",
        &[("Stop the service's daemon and remove the service", "acpmux daemon service uninstall")],
    ),
    (
        "daemon service status",
        &[("Whether the service is installed and running", "acpmux daemon service status")],
    ),
    (
        "daemon shutdown",
        &[
            ("Stop the daemon; hosted agents keep running", "acpmux daemon shutdown"),
            ("Stop the daemon and end every agent process", "acpmux daemon shutdown --end-agents"),
            ("Stop it for an external updater", "acpmux daemon shutdown --restart"),
        ],
    ),
    (
        "daemon config",
        &[
            ("Print the config path and contents", "acpmux daemon config"),
            (
                "Cap each session's memory host-wide",
                "acpmux daemon config --set session.memory_mb=8192",
            ),
            (
                "Go back to the computed memory cap",
                "acpmux daemon config --set session.memory_mb=default",
            ),
        ],
    ),
    (
        "daemon harnesses",
        &[("List configured harnesses with their defaults", "acpmux daemon harnesses")],
    ),
    (
        "daemon reload",
        &[("Reload the catalog config without stopping sessions", "acpmux daemon reload")],
    ),
    (
        "daemon retention",
        &[
            ("Show what a compaction pass would remove", "acpmux daemon retention --dry-run"),
            (
                "Compact logs of chats closed over 30 days",
                "acpmux daemon retention --older-than-days 30",
            ),
            (
                "Compact one chat, keeping old segments",
                "acpmux daemon retention --only review-27310 --archive ~/log-archive",
            ),
        ],
    ),
    (
        "daemon history-delete",
        &[
            (
                "Preview the chats a delete pass would remove",
                "acpmux daemon history-delete --dry-run",
            ),
            (
                "Delete chats unchanged over 180 days, exporting each first",
                "acpmux daemon history-delete --older-than-days 180 --export ~/chat-export",
            ),
            (
                "List Recently deleted: chats that can still be restored",
                "acpmux daemon history-delete --deleted",
            ),
            ("Restore a deleted chat", "acpmux daemon history-delete --restore review-27310"),
        ],
    ),
    (
        "daemon history-offload",
        &[(
            "List old archived chats cloud history would take",
            "acpmux daemon history-offload --dry-run",
        )],
    ),
    (
        "daemon transcript-offload",
        &[
            (
                "List the transcripts a pass would copy to cloud history",
                "acpmux daemon transcript-offload --dry-run",
            ),
            (
                "Bring back every transcript a pass removed",
                "acpmux daemon transcript-offload --restore-all",
            ),
        ],
    ),
    ("daemon schema", &[("Print the RPC schema as JSON", "acpmux daemon schema")]),
    (
        "daemon models",
        &[
            ("List the model ids each harness offers", "acpmux daemon models"),
            ("Probe every harness for its models again", "acpmux daemon models --refresh"),
        ],
    ),
    ("daemon felt", &[("Show felt-latency p50, p90 and p99", "acpmux daemon felt")]),
    (
        "daemon placement",
        &[(
            "Tell the tailnet front the workspace moved",
            r#"acpmux daemon placement '{"kind":"moved","workspace":"default","placement":{"ssh":"10.0.0.5:22"}}'"#,
        )],
    ),
];
