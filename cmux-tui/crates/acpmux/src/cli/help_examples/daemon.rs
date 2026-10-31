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
        "daemon start",
        &[
            ("Start the daemon and wait until it accepts clients", "acpmux daemon start"),
            ("Start it and print its status as JSON", "acpmux daemon start --json"),
        ],
    ),
    (
        "daemon restart",
        &[("Restart the daemon; hosted sessions resume after", "acpmux daemon restart")],
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
    ("daemon schema", &[("Print the RPC schema as JSON", "acpmux daemon schema")]),
    (
        "daemon models",
        &[
            ("List the model ids each harness offers", "acpmux daemon models"),
            ("Probe every harness for its models again", "acpmux daemon models --refresh"),
        ],
    ),
];
