//! `acpmux session …` help examples (see `help_examples/mod.rs`).

use super::Example;

pub(super) const EXAMPLES: &[(&str, &[Example])] = &[
    (
        "session",
        &[
            ("Show a session's state, model and pending requests", "acpmux session info coord"),
            ("Cancel the turn coord is running", "acpmux session cancel coord"),
            ("Read the last 20 turns of a review session", "acpmux session history review-27310"),
        ],
    ),
    (
        "session start",
        &[
            (
                "Queue a Codex review session on a mesh machine",
                "acpmux session start review-27310 --machine mini-3 -m codex/gpt-6-astra",
            ),
            (
                "Start a session asking for permissions in a folder there",
                "acpmux session start review --machine worker -m codex --policy ask --cwd /workspace",
            ),
            (
                "Retry an uncertain start without queueing it twice",
                "acpmux session start review --machine worker --idempotency-key 7c1e4b2a",
            ),
        ],
    ),
    (
        "session receipt",
        &[
            (
                "Check whether a queued mesh start was delivered",
                "acpmux session receipt 5d0f3a2c-9e1b-4c7d-8a6f-2b4e9c1d7a30",
            ),
            (
                "Read a receipt as JSON for a script",
                "acpmux session receipt 5d0f3a2c-9e1b-4c7d-8a6f-2b4e9c1d7a30 --json",
            ),
        ],
    ),
    (
        "session info",
        &[
            ("Show coord's state, model, policy and pending requests", "acpmux session info coord"),
            ("Show a session on another machine", "acpmux session info mini-3/review-27"),
            ("Print the details as JSON for a script", "acpmux session info coord --json"),
            ("Print only coord's session id", "acpmux session info coord --fields sessionId"),
            (
                "Print a few fields, nested ones by a dotted path",
                "acpmux session info review-27 --fields status,turn.activity,stuckReason",
            ),
        ],
    ),
    (
        "session cancel",
        &[
            ("Cancel the turn coord is running", "acpmux session cancel coord"),
            ("Cancel a session on another machine", "acpmux session cancel mini-3/review-27"),
        ],
    ),
    (
        "session stop",
        &[
            (
                "Stop a finished review's agent; it stays resumable",
                "acpmux session stop review-27310",
            ),
            ("Stop a session and delete its log", "acpmux session stop review-27310 --purge"),
            (
                "Stop it only if it is idle and still at the lastSeq you read (exit 6 if not)",
                "acpmux session stop review-27310 --if-idle --expect-revision 418",
            ),
            (
                "Stop a session by id through the mesh hub",
                "acpmux session stop 3f2a9c1e-8b4d-4e2a-9f1c-7d6e5b4a3c21 --mesh --id",
            ),
        ],
    ),
    (
        "session restart",
        &[
            ("Restart coord's agent on the installed version", "acpmux session restart coord"),
            ("Restart a session on another machine", "acpmux session restart mini-3/review-27"),
        ],
    ),
    (
        "session rename",
        &[
            (
                "Rename a session after the PR it works on",
                "acpmux session rename review review-27310",
            ),
            (
                "Rename a session on another machine",
                "acpmux session rename mini-3/scratch sidebar-fix",
            ),
        ],
    ),
    (
        "session detach",
        &[
            (
                "Stop a session you started from this one from showing its turns here",
                "acpmux session detach mac-studio-ultras",
            ),
            ("The same, and print the result as JSON", "acpmux session detach helper-2 --json"),
        ],
    ),
    (
        "session inbox",
        &[
            (
                "Print the digest of other agents' messages waiting on coord",
                "acpmux session inbox coord",
            ),
            ("Send them to coord now as one prompt", "acpmux session inbox coord --digest"),
        ],
    ),
    (
        "session move",
        &[
            (
                "Say where coord would go, changing nothing",
                "acpmux session move coord --machine mini-3 --dry-run",
            ),
            (
                "Move coord and its history to another machine",
                "acpmux session move coord --machine mini-3",
            ),
            (
                "Move every idle chat to the placement's pick",
                "acpmux session move --all-idle --machine auto",
            ),
        ],
    ),
    (
        "session resume",
        &[
            ("Run the prompts a failed turn held", "acpmux session resume coord"),
            ("Resume a session on a mesh machine", "acpmux session resume worker/review --mesh"),
        ],
    ),
    (
        "session fork",
        &[
            ("Fork coord to try another approach", "acpmux session fork coord -n coord-alt"),
            (
                "Fork a session into another worktree",
                "acpmux session fork coord -n coord-ios --cwd ~/Projects/cmux-ios",
            ),
        ],
    ),
    (
        "session set",
        &[
            ("Switch a session to another model", "acpmux session set coord model=opus"),
            ("Lower a session's thinking effort", "acpmux session set review-27310 effort=low"),
            (
                "Claim the team's coordinator address",
                "acpmux session set coord --team-address coordinator",
            ),
        ],
    ),
    (
        "session allow",
        &[(
            "Pick a deny option; only the cmux app may pick an allow",
            "acpmux session allow coord reject_once",
        )],
    ),
    (
        "session deny",
        &[
            ("Reject coord's pending permission request", "acpmux session deny coord"),
            (
                "Reject a request on another machine's session",
                "acpmux session deny mini-3/review-27",
            ),
        ],
    ),
    (
        "session answer",
        &[(
            "Print coord's pending questions and the command that answers them",
            "acpmux session answer coord",
        )],
    ),
    (
        "session export",
        &[
            ("Export a session bundle to the default folder", "acpmux session export coord"),
            (
                "Fetch another machine's session bundle here",
                "acpmux session export mini-3/review-27",
            ),
            (
                "Export a bundle into a chosen folder",
                "acpmux session export coord --dest ~/bundles",
            ),
        ],
    ),
    (
        "session import",
        &[
            (
                "Restore a bundle exported with --dest ~/bundles",
                "acpmux session import ~/bundles/mini-3-review-27",
            ),
            (
                "Import a bundle under a new name",
                "acpmux session import ~/bundles/coord -n coord-restored",
            ),
        ],
    ),
    (
        "session transfer",
        &[
            (
                "Move coord to a sibling build's daemon",
                "acpmux session transfer coord --to ~/.acpmux-dev/acpmux.sock",
            ),
            (
                "Move a chat even while its turn runs",
                "acpmux session transfer coord --to ~/.acpmux-dev/acpmux.sock --interrupt",
            ),
        ],
    ),
    (
        "session tail",
        &[
            ("Print coord's last 50 raw events", "acpmux session tail coord"),
            ("Follow a session's events as they arrive", "acpmux session tail review-27310 -f"),
            ("Print the events after a cursor", "acpmux session tail coord --since 812 --last 200"),
        ],
    ),
    (
        "session tag",
        &[
            (
                "Label a review session for an hour",
                "acpmux session tag review-27310 task=review pr=27310 --ttl 3600",
            ),
            ("Remove a label", "acpmux session tag review-27310 --remove pr"),
        ],
    ),
    (
        "session rules",
        &[
            ("Show a session's per-tool rules", "acpmux session rules coord"),
            (
                "Deny rm -rf and ask before shell commands",
                "acpmux session rules coord '{\"autoDeny\": [\"rm -rf\"], \"ask\": [\"execute\"]}'",
            ),
            ("Drop the session's rules", "acpmux session rules coord --clear"),
        ],
    ),
    (
        "session limits",
        &[
            ("Show how many sub-sessions coord runs and queues", "acpmux session limits coord"),
            (
                "From a parent session, let its child run 4 sub-sessions at once",
                "acpmux session limits coord-helper --max 4",
            ),
            (
                "From a parent session, give its child the default limit again",
                "acpmux session limits coord-helper --clear",
            ),
        ],
    ),
    (
        "session turn-cap",
        &[
            ("Show coord's turn cap", "acpmux session turn-cap coord"),
            ("Cap coord's turns at 30 minutes", "acpmux session turn-cap coord --minutes 30"),
            ("Turn the cap off for this session", "acpmux session turn-cap coord --off"),
        ],
    ),
    (
        "session history",
        &[
            ("List coord's last 20 turns", "acpmux session history coord"),
            ("List the last 5 turns of a review", "acpmux session history review-27310 -n 5"),
        ],
    ),
    (
        "session queue",
        &[
            ("List the prompts waiting on coord", "acpmux session queue list coord"),
            (
                "Take other agents' messages out of coord's queue",
                "acpmux session queue clear coord --from-agents",
            ),
        ],
    ),
    (
        "session queue list",
        &[
            ("List the prompts waiting on coord", "acpmux session queue list coord"),
            ("Print each queued prompt's whole text", "acpmux session queue list coord --json"),
        ],
    ),
    (
        "session queue remove",
        &[
            ("Take one queued prompt out", "acpmux session queue remove coord p-41"),
            ("Take several queued prompts out", "acpmux session queue remove coord p-41 p-42 p-43"),
        ],
    ),
    (
        "session queue clear",
        &[
            (
                "See which agent messages would be taken out",
                "acpmux session queue clear coord --from-agents --dry-run",
            ),
            (
                "Take every other agent's message out",
                "acpmux session queue clear coord --from-agents",
            ),
        ],
    ),
];
