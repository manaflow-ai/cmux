//! Help examples for the work groups: `task`, `process`, `worktree`, `briefs`, `bead`, `inbox`,
//! `forum`, `chats`, `hand`, `router` (see `help_examples/mod.rs`).

use super::Example;

pub(super) const EXAMPLES: &[(&str, &[Example])] = &[
    (
        "task",
        &[
            ("Give review-27310 a task", "acpmux task new review-27310 \"Review #27310\""),
            ("End your task as done", "acpmux task done t-3f9a2c1d --summary \"Merged #27310\""),
            ("List the tasks coord gave", "acpmux task ls --from coord"),
        ],
    ),
    (
        "task new",
        &[
            (
                "Give a session a task with a stop condition",
                "acpmux task new fix-27310 \"Fix the flaky resize test\" \
                 --stop \"#27310 is merged\"",
            ),
            (
                "Pipe the brief in on stdin",
                "printf 'Review the diff' | acpmux task new review-27310 \"Review #27310\" -",
            ),
            (
                "Link the task's tracker bead too",
                "acpmux task new fix-27310 \"Fix the resize lag\" --bead cx-cus7j",
            ),
        ],
    ),
    (
        "task done",
        &[
            (
                "Report a task done with its PR",
                "acpmux task done t-3f9a2c1d --summary \"Fixed the resize lag\" \
                 --pr https://github.com/manaflow-ai/cmux/pull/27310",
            ),
            (
                "Report a task done with the commit it made",
                "acpmux task done t-3f9a2c1d --summary \"Pushed the fix\" --sha 4e1c9b2",
            ),
        ],
    ),
    (
        "task blocked",
        &[(
            "End a task as blocked and say why",
            "acpmux task blocked t-3f9a2c1d --summary \"Not started\" --why \"Base is red\"",
        )],
    ),
    (
        "task failed",
        &[(
            "End a task as failed and say why",
            "acpmux task failed t-3f9a2c1d --summary \"Tests fail\" --why \"Crash in resize\"",
        )],
    ),
    (
        "task ls",
        &[
            ("From an agent session, list the tasks it gave", "acpmux task ls"),
            ("From an agent session, list its tasks still running", "acpmux task ls --open"),
            ("List every task on this daemon", "acpmux task ls --all"),
            ("List the tasks coord gave", "acpmux task ls --from coord"),
        ],
    ),
    (
        "process",
        &[
            ("List background processes agents started", "acpmux process list"),
            (
                "Follow a Claude Code background process's output",
                "acpmux process show coord/b7x2k1q -f",
            ),
            ("Stop a Claude Code or Codex background process", "acpmux process kill coord/b7x2k1q"),
        ],
    ),
    (
        "process list",
        &[
            ("List every background process agents started", "acpmux process list"),
            ("List only coord's processes", "acpmux process list --session coord"),
        ],
    ),
    (
        "process show",
        &[
            ("Print everything a Claude Code process printed", "acpmux process show coord/b7x2k1q"),
            (
                "Keep printing until a Claude Code process ends",
                "acpmux process show coord/b7x2k1q --follow",
            ),
            (
                "Show the Claude Code process a tool call started",
                "acpmux process show --session coord --tool-call toolu_01HqX9mZ",
            ),
        ],
    ),
    (
        "process kill",
        &[(
            "Stop a dev server a Claude Code or Codex agent left running",
            "acpmux process kill coord/b7x2k1q",
        )],
    ),
    (
        "process background",
        &[
            (
                "Move a Claude Code chat's running commands to the background",
                "acpmux process background coord",
            ),
            (
                "Move only the command one Claude Code tool call started",
                "acpmux process background coord --tool-call toolu_01HqX9mZ",
            ),
        ],
    ),
    (
        "worktree",
        &[
            ("List worktrees a cleanup would touch", "acpmux worktree list"),
            ("See what a cleanup would do without doing it", "acpmux worktree clean --dry-run"),
            ("Put a reclaimed worktree back", "acpmux worktree restore lane/fix-27310"),
        ],
    ),
    (
        "worktree list",
        &[
            ("List worktrees a cleanup would touch", "acpmux worktree list"),
            ("List every worktree, kept ones too", "acpmux worktree list --all"),
            ("Show what a full disk would reclaim", "acpmux worktree list --pressure critical"),
        ],
    ),
    (
        "worktree clean",
        &[
            ("Archive and remove idle worktrees", "acpmux worktree clean"),
            ("Report what a cleanup would do", "acpmux worktree clean --dry-run"),
            ("Clean only the worktrees under ~/wt", "acpmux worktree clean --root ~/wt"),
        ],
    ),
    (
        "worktree restore",
        &[
            ("Restore a worktree by its branch", "acpmux worktree restore lane/fix-27310"),
            (
                "Restore a worktree to another folder",
                "acpmux worktree restore ~/wt/fix-27310 --path ~/wt/fix-27310-back",
            ),
        ],
    ),
    (
        "worktree archives",
        &[
            ("List reclaimed worktrees, newest first", "acpmux worktree archives"),
            ("Include the ones already restored", "acpmux worktree archives --all"),
        ],
    ),
    (
        "briefs",
        &[
            ("List the briefs the daemon tracks", "acpmux briefs ls"),
            ("Steer a running brief", "acpmux briefs steer t-3f9a2c1d \"Rebase first\""),
        ],
    ),
    (
        "briefs ls",
        &[
            ("List the briefs the daemon tracks", "acpmux briefs ls"),
            ("List only the running briefs", "acpmux briefs ls --status running"),
        ],
    ),
    (
        "briefs steer",
        &[(
            "Send the brief's session new direction",
            "acpmux briefs steer t-3f9a2c1d \"Rebase on feat-cmux-next before pushing\"",
        )],
    ),
    (
        "briefs report",
        &[
            ("Report progress on a brief", "acpmux briefs report t-3f9a2c1d \"PR #27310 open\""),
            (
                "Report a brief's PR as merged",
                "acpmux briefs report t-3f9a2c1d --status merged \"#27310 merged\"",
            ),
        ],
    ),
    (
        "bead",
        &[
            ("Link a session to a tracker bead", "acpmux bead link fix-27310 cx-cus7j"),
            ("Find the sessions working on a bead", "acpmux bead ls cx-cus7j"),
        ],
    ),
    (
        "bead link",
        &[
            ("Link a session to a tracker bead", "acpmux bead link fix-27310 cx-cus7j"),
            (
                "Link another machine's session to two beads",
                "acpmux bead link mini-3/review-27 cx-cus7j cx-ncc.112",
            ),
        ],
    ),
    ("bead unlink", &[("Unlink a bead from a session", "acpmux bead unlink fix-27310 cx-cus7j")]),
    (
        "bead ls",
        &[
            ("Find the sessions linked to a bead", "acpmux bead ls cx-cus7j"),
            ("List the beads a session works on", "acpmux bead ls fix-27310 --session"),
        ],
    ),
    (
        "inbox",
        &[
            ("List the team messages the hub holds", "acpmux inbox"),
            ("Read one team message", "acpmux inbox read msg-8f2a"),
            ("Acknowledge a team message", "acpmux inbox ack msg-8f2a"),
        ],
    ),
    ("inbox list", &[("List the team messages the hub holds", "acpmux inbox list")]),
    ("inbox read", &[("Read one team message by id", "acpmux inbox read msg-8f2a")]),
    ("inbox ack", &[("Acknowledge a team message you handled", "acpmux inbox ack msg-8f2a")]),
    (
        "forum",
        &[
            ("List the current forum rules", "acpmux forum rules"),
            (
                "From an agent session, post a rule every session reads",
                "acpmux forum announce --key builds \"Build on CI\"",
            ),
        ],
    ),
    (
        "forum announce",
        &[
            (
                "From an agent session, post a rule every session reads",
                "acpmux forum announce --key builds \"No local builds; use cmux-ci test\"",
            ),
            (
                "From an agent session, end the rule on a key",
                "acpmux forum announce --key base --retire",
            ),
        ],
    ),
    ("forum rules", &[("List the current rules, newest per key", "acpmux forum rules")]),
    (
        "forum ack",
        &[("From the agent session that read it, mark a rule read", "acpmux forum ack post-3f9a")],
    ),
    (
        "chats",
        &[
            ("List this device's chats, newest first", "acpmux chats list"),
            ("Open a chat again", "acpmux chats open claude-code:5f0c2a9e"),
        ],
    ),
    (
        "chats list",
        &[
            ("List this device's chats, newest first", "acpmux chats list"),
            (
                "List Codex chats in one folder",
                "acpmux chats list --harness codex --folder ~/wt/cmux",
            ),
            ("Find chats about the resize lag", "acpmux chats list -q resize -n 10"),
        ],
    ),
    (
        "chats search",
        &[
            ("Find chats that talked about the resize lag", "acpmux chats search resize lag"),
            (
                "Search only Codex chats in one folder",
                "acpmux chats search flaky test --harness codex --folder ~/wt/cmux -n 5",
            ),
        ],
    ),
    (
        "chats open",
        &[
            ("Open a chat again", "acpmux chats open claude-code:5f0c2a9e"),
            (
                "Open a chat moved from a Linux machine",
                "acpmux chats open codex:019a2b3c --cwd-map /home/sam=/Users/sam",
            ),
            (
                "Open a chat whose folder is gone",
                "acpmux chats open claude-code:5f0c2a9e --cwd ~/wt",
            ),
        ],
    ),
    ("chats roots", &[("List the folders the chat index reads", "acpmux chats roots")]),
    (
        "hand",
        &[
            ("Show this hand's id, API and roots", "acpmux hand status"),
            (
                "Pair this machine with a Cloud Chief",
                "acpmux hand pair 4KQ7-X9PL --api https://cloud-api.cmux.dev",
            ),
        ],
    ),
    (
        "hand pair",
        &[
            (
                "Pair this machine as a sandbox hand",
                "acpmux hand pair 4KQ7-X9PL --api https://cloud-api.cmux.dev",
            ),
            (
                "Pair a Mac limited to one folder",
                "acpmux hand pair 4KQ7-X9PL --api https://cloud-api.cmux.dev --profile mac \
                 --root ~/Projects",
            ),
        ],
    ),
    ("hand run", &[("Connect and serve Cloud requests in the foreground", "acpmux hand run")]),
    ("hand status", &[("Show this hand's id, API, profile and roots", "acpmux hand status")]),
    ("router", &[("Start the local CodeRouter", "acpmux router serve")]),
    ("router serve", &[("Start the local router listeners", "acpmux router serve")]),
];
