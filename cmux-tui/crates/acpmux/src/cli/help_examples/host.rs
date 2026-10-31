//! `acpmux host …` help examples (see `help_examples/mod.rs`).

use super::Example;

pub(super) const EXAMPLES: &[(&str, &[Example])] = &[
    (
        "host",
        &[
            ("Check every peer's health before remote work", "acpmux host status"),
            ("See which machine should take a build", "acpmux host place --build"),
            ("List peers and whether they are connected", "acpmux host ls"),
        ],
    ),
    (
        "host add",
        &[
            ("Add a peer reached over your ssh config", "acpmux host add mini-3"),
            ("Add a peer at an ssh host under another name", "acpmux host add box ssh://mini-2"),
            (
                "Add a peer at a websocket URL with its token",
                "acpmux host add lab ws://10.0.0.5:47811 --token 3f9c2a7e",
            ),
        ],
    ),
    (
        "host ls",
        &[
            ("List peers and their connection state", "acpmux host ls"),
            ("List peers as JSON for a script", "acpmux host ls --json"),
        ],
    ),
    (
        "host status",
        &[
            ("Check every peer's health, this machine first", "acpmux host status"),
            ("Check one peer after a request to it failed", "acpmux host status mini-3"),
        ],
    ),
    (
        "host place",
        &[
            ("See where a new agent session should go, and why", "acpmux host place"),
            ("Pick a build host for a build or test suite", "acpmux host place --build"),
        ],
    ),
    (
        "host vm-host",
        &[
            ("Show whether this machine takes its owner's VM boundary", "acpmux host vm-host"),
            ("Show the VM boundary setting on a peer", "acpmux host vm-host mini-3"),
            ("Refuse the VM boundary on a peer", "acpmux host vm-host mini-3 off"),
        ],
    ),
    ("host rm", &[("Remove the peer mini-3", "acpmux host rm mini-3")]),
    (
        "host ticket",
        &[
            ("Mint a pairing ticket for a new client machine", "acpmux host ticket new"),
            ("List tickets and paired machines", "acpmux host ticket ls"),
        ],
    ),
    (
        "host ticket new",
        &[
            ("Mint a client ticket that lives 15 minutes", "acpmux host ticket new"),
            (
                "Mint a ticket that lets this machine drive the new one",
                "acpmux host ticket new --role daemon --ttl 2h --label mini-2",
            ),
            (
                "Mint a watch-only ticket for a laptop",
                "acpmux host ticket new --role read-only --label \"review laptop\"",
            ),
        ],
    ),
    (
        "host ticket ls",
        &[
            ("List tickets and paired machines", "acpmux host ticket ls"),
            ("List them as JSON", "acpmux host ticket ls --json"),
        ],
    ),
    (
        "host ticket revoke",
        &[
            (
                "Unpair a machine by name and close its connections",
                "acpmux host ticket revoke mini-2",
            ),
            ("Revoke an unused ticket by id", "acpmux host ticket revoke tk-7f3a2c"),
        ],
    ),
    (
        "host ticket full-access",
        &[(
            "Stop a paired machine running chats in Full access",
            "acpmux host ticket full-access mini-2 off",
        )],
    ),
    (
        "host join",
        &[
            (
                "Pair with the machine that minted a pasted ticket",
                "printf '%s\\n' \"$TICKET\" | acpmux host join",
            ),
            (
                "Pair a daemon-role ticket, saying where to reach this daemon",
                "printf '%s\\n' \"$TICKET\" | acpmux host join --advertise wss://mini-2:47811",
            ),
            ("Show this machine's cloud join status", "acpmux host join --status"),
        ],
    ),
    (
        "host consent",
        &[(
            "Ask to turn screen consent off; a shell is refused, the cmux app changes it",
            "acpmux host consent revoke --screen",
        )],
    ),
    (
        "host consent grant",
        &[(
            "Ask to turn control consent on; a shell is refused, the cmux app changes it",
            "acpmux host consent grant --control",
        )],
    ),
    (
        "host consent revoke",
        &[(
            "Ask to turn screen consent off; a shell is refused, the cmux app changes it",
            "acpmux host consent revoke --screen",
        )],
    ),
    (
        "host setup",
        &[
            ("Install acpmux on an ssh host and add it as a peer", "acpmux host setup build-mac"),
            (
                "Set up a host under another peer name and port",
                "acpmux host setup admin@10.0.0.7 --name lab --port 47812",
            ),
            (
                "Set up a Linux host without the update timer",
                "acpmux host setup mini-2 --no-auto-update",
            ),
        ],
    ),
    (
        "host update",
        &[
            ("Push this build to one peer and restart its daemon", "acpmux host update mini-3"),
            (
                "Update every idle peer, never moving one back",
                "acpmux host update --all --if-idle --keep-newer",
            ),
            (
                "Push prebuilt binaries for each peer's platform",
                "acpmux host update --all --binary-dir ~/dist/acpmux",
            ),
        ],
    ),
    (
        "host hold",
        &[
            (
                "Keep updates off a machine until tomorrow night",
                "acpmux host hold mini-3 --reason \"soak run\" --until 2026-10-31T23:59:59Z",
            ),
            ("List the machines held off updates", "acpmux host hold"),
            ("End the hold on mini-3", "acpmux host hold mini-3 --release"),
        ],
    ),
    (
        "host self-update",
        &[
            ("Bring this Linux host's daemon to the newest build", "acpmux host self-update"),
            ("Follow another channel's builds", "acpmux host self-update --channel main"),
        ],
    ),
    (
        "host enroll",
        &[
            ("Enroll a machine over ssh in one go", "acpmux host enroll mini-4"),
            (
                "Enroll a host and copy a harness profile to it",
                "acpmux host enroll admin@10.0.0.7 --name lab --harness codex",
            ),
            (
                "Enroll a host and add this machine as its peer too",
                "acpmux host enroll mini-2 --reverse",
            ),
        ],
    ),
    (
        "host approvals",
        &[
            ("List the Macs that may allow prompts here", "acpmux host approvals"),
            (
                "From this Mac, let its app allow a peer's prompts",
                "acpmux host approvals enroll mini-2",
            ),
        ],
    ),
    (
        "host approvals add",
        &[(
            "Let a Mac's cmux app allow this machine's prompts",
            "acpmux host approvals add --id mac-a1b2c3 --name \"Studio Mac\" --key \
             046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296\
             4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
        )],
    ),
    (
        "host approvals rm",
        &[("Stop a Mac's Allows here at once", "acpmux host approvals rm mac-a1b2c3")],
    ),
    (
        "host approvals enroll",
        &[
            (
                "From this Mac, let its app allow a peer's prompts",
                "acpmux host approvals enroll mini-2",
            ),
            ("Do the same for an ssh host", "acpmux host approvals enroll admin@10.0.0.7"),
        ],
    ),
    (
        "host approvals unenroll",
        &[("From this Mac, stop its Allows on a peer", "acpmux host approvals unenroll mini-2")],
    ),
    (
        "host doctor",
        &[
            ("Check a peer step by step, changing nothing", "acpmux host doctor mini-3"),
            (
                "Check an ssh host and repair what fails",
                "acpmux host doctor mini-2 --fix --reverse",
            ),
            ("Check this machine's one-line join", "acpmux host doctor --here"),
        ],
    ),
    (
        "host candidates",
        &[
            ("List tailnet machines that could be added", "acpmux host candidates"),
            ("Also try key-only ssh to each online machine", "acpmux host candidates --probe"),
        ],
    ),
];
