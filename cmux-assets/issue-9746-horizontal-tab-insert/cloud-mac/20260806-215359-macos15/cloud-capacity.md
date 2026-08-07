# Cloud Mac visual verification blocker

No full-screen CUA recording could be produced because neither supported runner pool assigned a Mac within the bounded 15-minute provisioning window.

- macOS 26 attempt: https://github.com/manaflow-ai/cmux-loader/actions/runs/31148006838
- macOS 15 compatibility attempt: https://github.com/manaflow-ai/cmux-loader/actions/runs/31148877428
- Both jobs remained queued with an empty `runner_name`; bootstrap, Tailscale, app launch, and recording never began.
- Package-level behavior verification completed separately: 216 XCTest cases and 7 Swift Testing cases passed with zero failures.

This is provider capacity, not an application or CUA failure.

