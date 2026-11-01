//! `acpmux harness …` help examples (see `help_examples/mod.rs`).

use super::Example;

pub(super) const EXAMPLES: &[(&str, &[Example])] = &[
    (
        "harness",
        &[
            ("List every harness and its problems", "acpmux harness list"),
            ("Check a harness end to end with one prompt", "acpmux harness doctor codex"),
            ("Add a harness from a shipped example", "acpmux harness add --example opencode"),
        ],
    ),
    (
        "harness list",
        &[
            ("List every harness with its kind and source file", "acpmux harness list"),
            ("Also list a repo's folder profiles", "acpmux harness list --folder ~/src/app"),
            ("List harnesses as JSON for a script", "acpmux harness list --json"),
        ],
    ),
    (
        "harness add",
        &[
            ("Add Codex from the shipped example", "acpmux harness add --example codex"),
            (
                "Add a CLI without ACP as a terminal harness",
                "acpmux harness add aider --command aider --protocol terminal",
            ),
            (
                "Add an ACP Registry agent at its pinned version",
                "acpmux harness add goose --registry",
            ),
        ],
    ),
    (
        "harness icon",
        &[
            ("Show the icon cmux uses for a harness and why", "acpmux harness icon acme"),
            ("Set an SF Symbol as the icon", "acpmux harness icon acme hammer.fill"),
            ("Drop the icon so cmux picks one again", "acpmux harness icon acme --clear"),
        ],
    ),
    (
        "harness login",
        &[
            ("Sign in to a harness", "acpmux harness login gemini"),
            ("Check whether a harness is signed in", "acpmux harness login gemini --status"),
            ("Show the sign-in methods a harness offers", "acpmux harness login gemini --list"),
        ],
    ),
    (
        "harness registry",
        &[
            ("List the ACP Registry's agents", "acpmux harness registry"),
            ("Fetch the registry again instead of the cache", "acpmux harness registry --refresh"),
        ],
    ),
    (
        "harness doctor",
        &[
            ("Check a harness with the handshake and one prompt", "acpmux harness doctor acme"),
            (
                "Check the handshake only, with no model call",
                "acpmux harness doctor acme --no-prompt",
            ),
            ("Check a repo's folder profile", "acpmux harness doctor review --folder ~/src/app"),
        ],
    ),
    (
        "harness enable",
        &[
            (
                "Allow a repo's folder profile after a prompt",
                "acpmux harness enable review --folder ~/src/app",
            ),
            (
                "Allow it without the prompt, from a script",
                "acpmux harness enable review --folder ~/src/app --yes",
            ),
        ],
    ),
    (
        "harness disable",
        &[(
            "Withdraw a folder profile's confirmation",
            "acpmux harness disable review --folder ~/src/app",
        )],
    ),
    (
        "harness run",
        &[
            ("Run a terminal harness here", "acpmux harness run aider"),
            ("Run it in a repo", "acpmux harness run aider --cwd ~/src/app"),
        ],
    ),
    (
        "harness secret",
        &[(
            "Store an endpoint key for a harness",
            "acpmux harness secret set acme ANTHROPIC_AUTH_TOKEN",
        )],
    ),
    (
        "harness secret set",
        &[
            (
                "Store a key from a hidden prompt",
                "acpmux harness secret set acme ANTHROPIC_AUTH_TOKEN",
            ),
            (
                "Store a key read from stdin",
                "printf 'sk-test' | acpmux harness secret set local CMUX_BYO_API_KEY",
            ),
        ],
    ),
    (
        "harness codex-runtime",
        &[
            ("Download the pinned Codex release", "acpmux harness codex-runtime install"),
            ("See whether the managed Codex is ready", "acpmux harness codex-runtime status"),
        ],
    ),
    (
        "harness codex-runtime install",
        &[(
            "Download and verify the pinned official Codex release (opt in; a Codex on PATH still wins)",
            "acpmux harness codex-runtime install",
        )],
    ),
    (
        "harness codex-runtime status",
        &[(
            "Print the managed Codex version, path and readiness",
            "acpmux harness codex-runtime status",
        )],
    ),
    (
        "harness reload",
        &[("Make the daemon read the profile files again", "acpmux harness reload")],
    ),
    ("harness guide", &[("Print the guide for integrating a harness", "acpmux harness guide")]),
    ("harness remove", &[("Move a profile to the backups folder", "acpmux harness remove acme")]),
    (
        "harness restore",
        &[(
            "Bring back a profile that remove backed up",
            "acpmux harness restore acme-1761800000000.toml",
        )],
    ),
];
