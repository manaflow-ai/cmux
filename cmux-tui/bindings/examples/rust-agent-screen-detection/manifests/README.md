# herdr agent-detection manifests

Nineteen of these TOML files are unchanged from
https://github.com/herdrdev/herdr (Apache-2.0, see LICENSE), at manifest
snapshot commit `2290257acb2085ce6842ba5c7e3ca50c3ba64f02`, path
`src/detect/manifests/`. `claude.toml` is byte-identical to upstream commit
`987b070fbfa187e85009b45cd7e208fc6175ff6a`, which stops a background shell
from masking an idle prompt or a permission blocker. `grok.toml` is based on
the snapshot file and carries one cmux correction: idle OSC progress wins over
a generic custom title, while an explicit spinner still wins over retained idle metadata.
The local patch version is `2026.07.16.2.1`. `github-copilot.toml` is
byte-identical to the upstream snapshot, including its background-agent
waiting row, at version `2026.08.29.1`. The cmux package adapts their
semantics in the separately attributed Rust engine. Do not fetch herdr's
manifest update endpoint. Refresh the 19 unchanged files from the exact
snapshot commit, take Claude from its stated upstream correction commit, and
reapply the Grok local correction when changing this pin.

SHA256SUMS records the bytes embedded by the plugin. The provenance test
checks this record before the bundled set is compiled, so an accidental edit
cannot silently change a vendored rule. The record is not a release signature:
remote updates still need authenticated, signed catalog data before they can be
treated as trusted.

The capability audit was rerun against herdr's agent-surface revision
`987b070fbfa187e85009b45cd7e208fc6175ff6a`. It found the exact Pi bundled CLI
path correction from `b1ff4582e9688f52ffb943cfa8bee4871ae122e4` and the Claude
background-shell manifest correction from `987b070fbfa187e85009b45cd7e208fc6175ff6a`.
These two corrections are ported and tested. The multi-client tab-view, delayed-prompt,
recent-read, graphics, Windows input, and sidebar-focus commits are host/client
work outside this manifest package. The package does not claim parity with
that transport or input work. The repository tip checked on 2026-09-02 is
`94f6d9c0d9bb9cf9ffae99d8bbfb09e9bf2fc9e0`; commits after the agent-surface
revision do not change `src/detect` or the manifests. The agent-surface
revision is the reproducible capability-audit pin.
