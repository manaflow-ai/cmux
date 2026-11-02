//! Help examples for `acpmux` itself and its top-level commands (see `help_examples/mod.rs`).

use super::Example;

pub(super) const EXAMPLES: &[(&str, &[Example])] = &[
    (
        "",
        &[
            ("List sessions on every machine", "acpmux ls"),
            (
                "Send coord a message and return at once",
                "acpmux send --no-wait coord \"PR 27310 is green\"",
            ),
            (
                "Start a Codex session on a task without opening the TUI",
                "acpmux new -m codex -n fix-27310 -d \"Fix the failing test\"",
            ),
            ("Print a session's last reply", "acpmux last review-27310"),
        ],
    ),
    (
        "dispatch",
        &[
            (
                "Send a brief to the least-loaded allowed machine",
                "acpmux dispatch ~/notes/brief.md -m codex/gpt-6-astra",
            ),
            (
                "Send a brief to a named machine with a title and stop condition",
                "acpmux dispatch ~/notes/brief.md --machine mini-3 --title \"Fix 27310\" \
                 --stop-condition \"PR 27310 merged\"",
            ),
            (
                "Send a brief read from stdin to this machine",
                "printf 'Audit the retry path' | acpmux dispatch - --machine local",
            ),
        ],
    ),
    (
        "resolve",
        &[
            (
                "Find the session behind a PR footer's agent link",
                "acpmux resolve \"https://cmux.com/deeplink/agent?id=aid-3f9c2a\"",
            ),
            (
                "Show the machine, lane and pull requests of another machine's session",
                "acpmux resolve mini-3/review-27",
            ),
            ("Show this session's own ids and link", "acpmux resolve @"),
        ],
    ),
    (
        "new",
        &[
            (
                "Start a Codex review session without opening the TUI",
                "acpmux new -m codex/gpt-6-astra -e high -n review-27310 -d \"Review PR 27310\"",
            ),
            (
                "Start an agent in its own worktree on a brief that reports to coord",
                "acpmux new -n fix-27310 --worktree ~/Projects/cmux@origin/main \
                 --prompt-file ~/notes/brief.md --report-to coord -d",
            ),
            (
                "Start a session from inside an agent that is not its child (no turn cards here)",
                "acpmux new -n scratch --no-parent -d \"Look into the flaky test\"",
            ),
            (
                "Run one prompt and print only the final reply",
                "acpmux run -m claude \"Summarize the open TODOs in this repo\"",
            ),
        ],
    ),
    (
        "wait",
        &[
            (
                "Wait up to 30 minutes for a turn and print its reply",
                "acpmux wait review-27310 --timeout 1800 --print",
            ),
            (
                "Wait until both review sessions finish",
                "acpmux wait review-27310 review-27311 --all",
            ),
            (
                "Wait until a session's transcript says SHIP",
                "acpmux wait review-27310 --match SHIP",
            ),
        ],
    ),
    (
        "ensure",
        &[
            (
                "Get coord, creating a Claude session when missing",
                "acpmux ensure coord -m claude/opus",
            ),
            (
                "Get a review session on another machine, created in a folder there",
                "acpmux ensure review-27 --machine mini-3 -m codex --cwd ~/Projects/cmux",
            ),
        ],
    ),
    (
        "continue",
        &[
            (
                "Prepare to continue a session's work on Codex",
                "acpmux continue review-27310 --to codex",
            ),
            (
                "Attach a checked checkpoint to a prepared handoff",
                "acpmux continue --handoff 019a3c2e-7f41-7a2b-9c3d-5e6f7a8b9c0d \
                 --checkpoint lane/fix-27310 --attest",
            ),
            (
                "Start the handoff at a checked checkpoint: send its first message",
                "acpmux continue --handoff 019a3c2e-7f41-7a2b-9c3d-5e6f7a8b9c0d \
                 --checkpoint lane/fix-27310 --attest --start",
            ),
        ],
    ),
    (
        "retry",
        &[
            ("Retry a session's failed last turn now", "acpmux retry review-27310"),
            (
                "Retry a failed turn of a session on another machine",
                "acpmux retry mini-3/review-27",
            ),
        ],
    ),
    (
        "history",
        &[
            ("Show coord's last 20 turns", "acpmux history coord"),
            ("Show only the last 5 turns of a review session", "acpmux history review-27310 -n 5"),
        ],
    ),
    (
        "compare",
        &[(
            "Run one prompt on Claude and Codex and compare",
            "acpmux compare -m claude -m codex/gpt-6-astra \"Why does this test flake?\"",
        )],
    ),
    (
        "skill",
        &[
            ("Print the guide for driving acpmux from a script or agent", "acpmux skill"),
            ("Print the same guide by its other name", "acpmux guide"),
        ],
    ),
    (
        "capabilities",
        &[
            ("List the protocol capability ids this build serves", "acpmux capabilities"),
            ("Print them as a JSON object", "acpmux capabilities --json"),
        ],
    ),
    (
        "preset",
        &[
            ("List every preset", "acpmux preset"),
            (
                "Set a preset for Codex on Astra at high effort",
                "acpmux preset astra harness=codex model=gpt-6-astra effort=high",
            ),
            ("Remove a preset", "acpmux preset astra --clear"),
        ],
    ),
    (
        "defaults",
        &[
            ("Show the defaults for Claude sessions", "acpmux defaults claude"),
            (
                "Make Claude sessions default to Opus at high effort",
                "acpmux defaults claude model=claude-opus-5 effort=high",
            ),
            ("Clear one default key", "acpmux defaults claude effort="),
        ],
    ),
    (
        "last",
        &[
            ("Print a review session's last reply", "acpmux last review-27310"),
            ("Print coord's last 3 replies, newest last", "acpmux last coord -n 3"),
            (
                "Print the last reply of a session on another machine",
                "acpmux last mini-3/review-27",
            ),
        ],
    ),
    (
        "pending",
        &[
            ("List permission requests waiting for an answer", "acpmux pending"),
            ("List them as JSON for a script", "acpmux pending --json"),
        ],
    ),
    (
        "send",
        &[
            (
                "Send to the one live `review`, here or on another machine",
                "acpmux send review \"ship it\"",
            ),
            ("Send to `review` on machine hb", "acpmux send hb/review \"ship it\""),
            ("Send to a session by its id prefix", "acpmux send 0199aaaa \"ship it\""),
            (
                "Send coord a message and return at once",
                "acpmux send --no-wait coord \"PR 27310 merged\"",
            ),
            (
                "Ask a session a question and print only its reply",
                "acpmux send review-27310 -q \"Is the diff safe to land?\"",
            ),
            (
                "Send a screenshot with the message",
                "acpmux send fix-27310 --attach ~/notes/before.png \"The caret jumps after paste\"",
            ),
            (
                "Message every live session tagged area=acpmux, on every machine",
                "acpmux send --tag area=acpmux \"base is green again; update your PRs\"",
            ),
            (
                "List who a tagged send would reach, and send nothing",
                "acpmux send --tag area=acpmux --dry-run \"hello\"",
            ),
        ],
    ),
    (
        "deliver",
        &[
            (
                "From an agent session, leave Sam a report without waking anyone",
                "acpmux deliver --target reports:sam \"PR 27310 landed\"",
            ),
            (
                "From an agent session, leave a report from stdin for coordinators",
                "printf 'Nightly is green' | acpmux deliver --target reports:sam \
                 --audience coordinator -",
            ),
        ],
    ),
    (
        "attach",
        &[
            ("Open the TUI on coord", "acpmux attach coord"),
            ("Open the TUI on the session list", "acpmux attach"),
            ("Follow a session as plain text", "acpmux attach review-27310 --plain"),
        ],
    ),
    (
        "stdio",
        &[
            ("Serve an editor ACP sessions on Claude", "acpmux stdio -m claude"),
            (
                "Serve Codex sessions that approve edits",
                "acpmux stdio -m codex/gpt-6-astra --policy approve-edits",
            ),
        ],
    ),
    (
        "cli-agent",
        &[
            (
                "Make a CLI a harness: prompt on stdin, reply from stdout",
                "acpmux cli-agent -- /usr/local/bin/my-agent --plain",
            ),
            (
                "Pass the prompt as an argument to a program that needs a terminal",
                "acpmux cli-agent --prompt-arg --tty -- unii chat",
            ),
        ],
    ),
    (
        "uniichat-agent",
        &[
            ("Serve ACP backed by uniichat.com", "acpmux uniichat-agent"),
            (
                "Serve ACP backed by your own `unii serve`",
                "acpmux uniichat-agent --url http://127.0.0.1:8787",
            ),
        ],
    ),
    (
        "web",
        &[
            ("Open the dashboard in the browser", "acpmux web"),
            ("Only print the dashboard URL", "acpmux web --no-open"),
        ],
    ),
];
