//! Help examples for the work groups: `task`, `process`, `worktree`, `briefs`, `bead`, `inbox`,
//! `forum`, `watch`, `chats`, `hand`, `router` (see `help_examples/mod.rs`).

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
            (
                "Every process acpmux started here, who owns it now and whether it is in use",
                "acpmux process",
            ),
            ("List background processes agents started", "acpmux process list"),
            (
                "Follow a Claude Code background process's output",
                "acpmux process show coord/b7x2k1q -f",
            ),
            ("Stop a Claude Code or Codex background process", "acpmux process kill coord/b7x2k1q"),
        ],
    ),
    (
        "gc",
        &[
            ("What acpmux would end as orphaned, and what it refuses and why", "acpmux gc"),
            ("End the proven orphans and log each with its reason", "acpmux gc --apply"),
        ],
    ),
    (
        "process list",
        &[
            ("List every background process agents started", "acpmux process list"),
            ("List only coord's processes", "acpmux process list --session coord"),
            ("List only the ones still running", "acpmux process list --running"),
        ],
    ),
    (
        "process owner",
        &[(
            "Which session owns pid 4242, and whether it may be ended",
            "acpmux process owner 4242",
        )],
    ),
    (
        "process left-behind",
        &[("What ended agent hosts left running on this machine", "acpmux process left-behind")],
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
        &[
            (
                "Stop a dev server a Claude Code or Codex agent left running",
                "acpmux process kill coord/b7x2k1q",
            ),
            ("End a pid that is yours or left behind (logged)", "acpmux process kill --pid 4242"),
        ],
    ),
    (
        "process start",
        &[(
            "From an agent chat's shell: run a dev server as a task that outlives hibernation",
            "acpmux process start --description 'dev server' -- 'npm run dev'",
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
        "group",
        &[
            ("List sidebar groups, duplicates marked", "acpmux group ls"),
            ("Put a session in the Leads group", "acpmux group move coord Leads"),
            ("Merge same-named groups", "acpmux group tidy --apply"),
        ],
    ),
    (
        "race",
        &[
            (
                "Race two models on a task and let a third review",
                "acpmux race new -m claude -m codex --reviewer claude 'Fix the flaky test'",
            ),
            ("List this chat's races", "acpmux race ls"),
        ],
    ),
    (
        "race new",
        &[(
            "Race two models on a task in a file",
            "acpmux race new -m claude -m codex --reviewer claude --prompt-file task.md",
        )],
    ),
    ("race show", &[("Read a race and the reviewer's pick", "acpmux race show RACE_ID")]),
    ("race stop", &[("Stop a race's agents, keeping its results", "acpmux race stop RACE_ID")]),
    ("race ls", &[("List this chat's races", "acpmux race ls")]),
    ("race stats", &[("Wins per model in this chat", "acpmux race stats")]),
    (
        "fork-run",
        &[
            (
                "Fork a Cloud machine three ways",
                "acpmux fork-run start --workspace WS --machine vm_ID --harness claude,codex,pi",
            ),
            ("Keep the codex fork", "acpmux fork-run select RUN_ID CHILD_ID --workspace WS"),
        ],
    ),
    (
        "fork-run start",
        &[(
            "One fork per harness, each continuing a chat",
            "acpmux fork-run start --workspace WS --machine vm_ID --harness claude --harness codex --session S",
        )],
    ),
    (
        "fork-run status",
        &[(
            "Wait up to 3 minutes for the forks",
            "acpmux fork-run status RUN_ID --workspace WS --wait 180",
        )],
    ),
    (
        "fork-run select",
        &[("Keep one ready fork", "acpmux fork-run select RUN_ID CHILD_ID --workspace WS")],
    ),
    ("group ls", &[("List sidebar groups as JSON", "acpmux group ls --json")]),
    ("group move", &[("Put a session in the Leads group", "acpmux group move coord Leads")]),
    (
        "account",
        &[
            ("List every account and which is the default", "acpmux account list"),
            ("Add a second ChatGPT account", "acpmux account sign-in --family codex"),
            ("Make it the Codex default", "acpmux account switch codex-2"),
        ],
    ),
    (
        "account sign-in",
        &[
            ("Sign an account in again", "acpmux account sign-in --account codex-2"),
            (
                "Add a Claude account with a name",
                "acpmux account sign-in --family claude --name Work",
            ),
            ("Add a GitHub account through gh", "acpmux account sign-in --family github"),
        ],
    ),
    (
        "account sign-out",
        &[("Sign an account out; it stays listed", "acpmux account sign-out codex-2")],
    ),
    (
        "account switch",
        &[("Make a GitHub account gh's active one", "acpmux account switch github:alice")],
    ),
    ("account remove", &[("Remove an account's route", "acpmux account remove claude-2")]),
    ("account list", &[("Every account as JSON", "acpmux --json account list")]),
    (
        "account readiness",
        &[
            ("Which of GitHub, Codex and Claude still need a sign-in", "acpmux account readiness"),
            ("The same as JSON, for a script", "acpmux --json account readiness"),
        ],
    ),
    (
        "group tidy",
        &[
            ("See which groups a tidy would merge", "acpmux group tidy"),
            ("Merge them", "acpmux group tidy --apply"),
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
        "bridge",
        &[
            ("Connect Claude Desktop and Codex Desktop to cmux", "acpmux bridge connect"),
            ("Message Codex Desktop", "acpmux bridge send codex-desktop \"Review PR 812 please\""),
        ],
    ),
    (
        "bridge connect",
        &[
            ("Connect both desktop apps; restart them after", "acpmux bridge connect"),
            (
                "See what connecting Codex Desktop would change",
                "acpmux bridge connect codex --dry-run",
            ),
        ],
    ),
    (
        "bridge send",
        &[(
            "Answer Claude Desktop from a cmux session",
            "acpmux bridge send claude-desktop \"Done: the fix is on lane/x\"",
        )],
    ),
    (
        "bridge inbox",
        &[("Read what was left for Codex Desktop", "acpmux bridge inbox codex-desktop --peek")],
    ),
    (
        "desktop",
        &[
            ("Give every agent app here the cmux tools", "acpmux desktop link"),
            ("See which apps have the cmux tools", "acpmux desktop status"),
        ],
    ),
    (
        "desktop link",
        &[
            (
                "Give Claude, Codex, OpenCode, Gemini CLI, Qwen Code and pi the cmux tools",
                "acpmux desktop link",
            ),
            ("See what linking Codex would change", "acpmux desktop link --app codex --dry-run"),
            ("Give only OpenCode the cmux tools", "acpmux desktop link --app opencode"),
        ],
    ),
    (
        "desktop unlink",
        &[
            ("Take the cmux tools back from every app", "acpmux desktop unlink"),
            ("Take them back from Claude desktop", "acpmux desktop unlink --app claude-desktop"),
        ],
    ),
    (
        "desktop status",
        &[
            ("See which apps are here and which have the cmux tools", "acpmux desktop status"),
            ("The same as JSON for a script", "acpmux desktop status --json"),
        ],
    ),
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
        "trigger",
        &[
            (
                "Wake the Cloud chat fixer when CI fails in acme/app",
                "acpmux trigger create --repo acme/app --on ci_failure --machine m1 --workspace w1 --session fixer --cwd /repo --harness codex \"CI failed; find why and fix it\"",
            ),
            ("The triggers registered from here, read back from Cloud", "acpmux trigger ls"),
        ],
    ),
    (
        "trigger create",
        &[
            (
                "On a PR comment or a CI failure, wake the Cloud chat fixer",
                "acpmux trigger create --repo acme/app --on pr_comment --on ci_failure --machine m1 --workspace w1 --session fixer --cwd /repo --harness claude \"Read the new comment or failure and act on it\"",
            ),
            (
                "A new chat per delivery, at most 10 a day",
                "acpmux trigger create --repo acme/app --on pr_opened --start-session --max-runs-per-day 10 --machine m1 --workspace w1 --session review --cwd /repo --harness codex \"Review this PR\"",
            ),
            (
                "A generic signed webhook instead of GitHub",
                "acpmux trigger create --webhook --repo acme/app --on deploy.failed --machine m1 --workspace w1 --session ops --cwd /repo --harness codex \"The deploy failed; look\"",
            ),
        ],
    ),
    (
        "trigger ls",
        &[
            ("The triggers registered from here, on or off", "acpmux trigger ls"),
            ("Read one trigger by id", "acpmux trigger ls 3f1c2a9e-8b7d-4c6e-9a5b-1d2e3f4a5b6c"),
        ],
    ),
    (
        "trigger rm",
        &[(
            "Turn a trigger off and read it back disabled",
            "acpmux trigger rm 3f1c2a9e-8b7d-4c6e-9a5b-1d2e3f4a5b6c",
        )],
    ),
    (
        "watch",
        &[
            (
                "From a coordinator session, be woken when a worker is done or blocked",
                "acpmux watch add review-27310 fix-27311",
            ),
            ("List watches and the wakes they owe", "acpmux watch ls"),
        ],
    ),
    (
        "watch add",
        &[
            (
                "Wake coord once when a worker on any host reports a blocker",
                "acpmux watch add review-27310 my-linux/fix-27311 --to coord --match BLOCKER",
            ),
            (
                "Wake coord only when a worker asks for permission or closes",
                "acpmux watch add fix-27311 --to coord --until permission,closed",
            ),
        ],
    ),
    ("watch ls", &[("List watches and the wakes they still owe", "acpmux watch ls --json")]),
    (
        "watch rm",
        &[("Remove a watch; wakes it already owes still arrive", "acpmux watch rm 019a3f9c")],
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
    (
        "share-host",
        &[
            ("See whether this Mac's share host runs, and why not", "acpmux share-host status"),
            ("Let viewers see this Mac's screen", "acpmux share-host on"),
        ],
    ),
    (
        "share-host status",
        &[
            ("Show the share host, its hub link and live shares", "acpmux share-host status"),
            ("Read the share host's status as JSON", "acpmux share-host status --json"),
        ],
    ),
    ("share-host on", &[("Turn sharing this Mac's screen on", "acpmux share-host on")]),
    ("share-host off", &[("Turn sharing this Mac's screen off", "acpmux share-host off")]),
    (
        "share-host screens",
        &[
            ("List the live shares this machine hosts or views", "acpmux share-host screens"),
            ("Read them as JSON", "acpmux share-host screens --json"),
        ],
    ),
    (
        "share-host start",
        &[
            ("Share this machine's screen to your iPhone", "acpmux share-host start --to iphone"),
            (
                "Share it view-only to another device, by id prefix",
                "acpmux share-host start --to 3f2a --view-only",
            ),
        ],
    ),
    ("share-host stop", &[("End a share by its session id prefix", "acpmux share-host stop 7c1e")]),
    (
        "share-host move",
        &[
            ("Hand a live share to another viewer", "acpmux share-host move 7c1e --to macbook"),
            (
                "Show the viewer another host's screen",
                "acpmux share-host move 7c1e --host mac-mini",
            ),
        ],
    ),
    (
        "share-host link",
        &[
            ("Print the view-only link to this Mac's screen", "acpmux share-host link"),
            (
                "Link a run's virtual display, labeled with the run's name",
                "acpmux share-host link --display 5 --name ui-check",
            ),
            ("Ask for full control instead of view-only", "acpmux share-host link --control"),
        ],
    ),
    ("router", &[("Start the local CodeRouter", "acpmux router serve")]),
    ("router serve", &[("Start the local router listeners", "acpmux router serve")]),
];
