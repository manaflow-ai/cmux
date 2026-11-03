//! `acpmux machine …` help examples, old spelling `acpmux host …` (see `help_examples/mod.rs`).

use super::Example;

pub(super) const EXAMPLES: &[(&str, &[Example])] = &[
    (
        "machine",
        &[
            ("Check every machine's health before remote work", "acpmux machine status"),
            ("See which machine should take a build", "acpmux machine pick --build"),
            ("List machines and whether they are connected", "acpmux machine ls"),
        ],
    ),
    (
        "machine add",
        &[
            ("Add a machine reached over your ssh config", "acpmux machine add mini-3"),
            (
                "Add a machine at an ssh host under another name",
                "acpmux machine add box ssh://mini-2",
            ),
            (
                "Add a machine at a websocket URL with its token",
                "acpmux machine add lab ws://10.0.0.5:47811 --token 3f9c2a7e",
            ),
        ],
    ),
    (
        "machine ls",
        &[
            ("List machines and their connection state", "acpmux machine ls"),
            ("List machines as JSON for a script", "acpmux machine ls --json"),
        ],
    ),
    (
        "machine status",
        &[
            ("Check every machine's health, this machine first", "acpmux machine status"),
            ("Check one machine after a request to it failed", "acpmux machine status mini-3"),
        ],
    ),
    (
        "machine pick",
        &[
            ("See where a new agent session should go, and why", "acpmux machine pick"),
            ("Pick a build machine for a build or test suite", "acpmux machine pick --build"),
        ],
    ),
    (
        "machine dedicated",
        &[
            (
                "Show whether this machine is dedicated (no per-session sandbox)",
                "acpmux machine dedicated",
            ),
            ("Show whether another machine is dedicated", "acpmux machine dedicated mini-3"),
            (
                "Stop another machine running agents unsandboxed",
                "acpmux machine dedicated mini-3 off",
            ),
        ],
    ),
    ("machine load", &[("Print this machine's load now as JSON", "acpmux machine load --json")]),
    (
        "machine notice",
        &[(
            "Add a muted line to every live chat here",
            "acpmux machine notice --text \"Machine grew to 4 vCPU / 8 GiB\"",
        )],
    ),
    ("machine rm", &[("Remove the machine mini-3", "acpmux machine rm mini-3")]),
    (
        "machine ticket",
        &[
            ("Mint a pairing ticket for a new client machine", "acpmux machine ticket new"),
            ("List tickets and paired machines", "acpmux machine ticket ls"),
        ],
    ),
    (
        "machine ticket new",
        &[
            ("Mint a client ticket that lives 15 minutes", "acpmux machine ticket new"),
            (
                "Mint a ticket that lets this machine drive the new one",
                "acpmux machine ticket new --role daemon --ttl 2h --label mini-2",
            ),
            (
                "Mint a watch-only ticket for a laptop",
                "acpmux machine ticket new --role read-only --label \"review laptop\"",
            ),
        ],
    ),
    (
        "machine ticket ls",
        &[
            ("List tickets and paired machines", "acpmux machine ticket ls"),
            ("List them as JSON", "acpmux machine ticket ls --json"),
        ],
    ),
    (
        "machine ticket revoke",
        &[
            (
                "Unpair a machine by name and close its connections",
                "acpmux machine ticket revoke mini-2",
            ),
            ("Revoke an unused ticket by id", "acpmux machine ticket revoke tk-7f3a2c"),
        ],
    ),
    (
        "machine ticket full-access",
        &[(
            "Stop a paired machine running chats in Full access",
            "acpmux machine ticket full-access mini-2 off",
        )],
    ),
    (
        "machine join",
        &[
            (
                "Pair with the machine that minted a pasted ticket",
                "printf '%s\\n' \"$TICKET\" | acpmux machine join",
            ),
            (
                "Pair a daemon-role ticket, saying where to reach this daemon",
                "printf '%s\\n' \"$TICKET\" | acpmux machine join --advertise wss://mini-2:47811",
            ),
            ("Show this machine's cloud join status", "acpmux machine join --status"),
        ],
    ),
    (
        "machine consent",
        &[(
            "Ask to turn screen consent off; a shell is refused, the cmux app changes it",
            "acpmux machine consent revoke --screen",
        )],
    ),
    (
        "machine consent grant",
        &[(
            "Ask to turn control consent on; a shell is refused, the cmux app changes it",
            "acpmux machine consent grant --control",
        )],
    ),
    (
        "machine consent revoke",
        &[(
            "Ask to turn screen consent off; a shell is refused, the cmux app changes it",
            "acpmux machine consent revoke --screen",
        )],
    ),
    (
        "machine setup",
        &[
            (
                "Install acpmux on an ssh host and add it as a machine",
                "acpmux machine setup build-mac",
            ),
            (
                "Set up a machine under another name and port",
                "acpmux machine setup admin@10.0.0.7 --name lab --port 47812",
            ),
            (
                "Set up a Linux machine without the update timer",
                "acpmux machine setup mini-2 --no-auto-update",
            ),
        ],
    ),
    (
        "machine update",
        &[
            (
                "Push this build to one machine and restart its daemon",
                "acpmux machine update mini-3",
            ),
            (
                "Update every idle machine, never moving one back",
                "acpmux machine update --all --if-idle --keep-newer",
            ),
            (
                "Push prebuilt binaries for each machine's platform",
                "acpmux machine update --all --binary-dir ~/dist/acpmux",
            ),
        ],
    ),
    (
        "machine hold",
        &[
            (
                "Keep updates off a machine until tomorrow night",
                "acpmux machine hold mini-3 --reason \"soak run\" --until 2026-10-31T23:59:59Z",
            ),
            ("List the machines held off updates", "acpmux machine hold"),
            ("End the hold on mini-3", "acpmux machine hold mini-3 --release"),
        ],
    ),
    (
        "machine self-update",
        &[
            ("Bring this Linux machine's daemon to the newest build", "acpmux machine self-update"),
            ("Follow another channel's builds", "acpmux machine self-update --channel main"),
        ],
    ),
    (
        "machine enroll",
        &[
            ("Enroll a machine over ssh in one go", "acpmux machine enroll mini-4"),
            (
                "Enroll a machine and copy a harness profile to it",
                "acpmux machine enroll admin@10.0.0.7 --name lab --harness codex",
            ),
            (
                "Enroll a machine and add this one on it too",
                "acpmux machine enroll mini-2 --reverse",
            ),
        ],
    ),
    (
        "machine approvals",
        &[
            ("List the Macs that may allow prompts here", "acpmux machine approvals"),
            (
                "From this Mac, let its app allow a machine's prompts",
                "acpmux machine approvals enroll mini-2",
            ),
        ],
    ),
    (
        "machine approvals add",
        &[(
            "Let a Mac's cmux app allow this machine's prompts",
            "acpmux machine approvals add --id mac-a1b2c3 --name \"Studio Mac\" --key \
             046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296\
             4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
        )],
    ),
    (
        "machine approvals rm",
        &[("Stop a Mac's Allows here at once", "acpmux machine approvals rm mac-a1b2c3")],
    ),
    (
        "machine approvals enroll",
        &[
            (
                "From this Mac, let its app allow a machine's prompts",
                "acpmux machine approvals enroll mini-2",
            ),
            ("Do the same for an ssh host", "acpmux machine approvals enroll admin@10.0.0.7"),
        ],
    ),
    (
        "machine approvals unenroll",
        &[(
            "From this Mac, stop its Allows on a machine",
            "acpmux machine approvals unenroll mini-2",
        )],
    ),
    (
        "machine doctor",
        &[
            ("Check a machine step by step, changing nothing", "acpmux machine doctor mini-3"),
            (
                "Check an ssh host and repair what fails",
                "acpmux machine doctor mini-2 --fix --reverse",
            ),
            ("Check this machine's one-line join", "acpmux machine doctor --here"),
        ],
    ),
    (
        "machine candidates",
        &[
            ("List tailnet machines that could be added", "acpmux machine candidates"),
            ("Also try key-only ssh to each online machine", "acpmux machine candidates --probe"),
        ],
    ),
];
