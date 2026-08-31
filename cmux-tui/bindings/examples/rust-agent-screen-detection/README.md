# cmux agent screen-detection plugin

This is a userland reference plugin. cmux core starts and supervises the
process, but this package owns process identification, terminal sampling,
screen rules, pacing, and the herdr-derived manifests.

Publish this directory as the root of its own Git repository, then install that
repository with:

```text
cmux agent plugin install <agent-plugin-repository-url>
cmux agent plugin use agent-screen-detection
```

This reference package is not a separate repository yet. The placeholder URL
must be replaced with the URL of the repository that publishes this directory.

The source tree is kept in the cmux repository as a reference package. The
plugin manager expects `cmux-plugin.toml` at the root of the repository that it
clones, so the parent cmux repository is not a valid install URL for this
example.

The plugin uses the public Rust SDK. In this repository the SDK is a path
dependency. A standalone publication must replace it with the matching
released `cmux-sdk` version before external users build the package. It
registers a namespaced journal
producer, reads terminal process metadata and viewport text, and appends
`cmux.agent-plugin.v1` events. A different implementation can use Python,
another language, or a different ruleset without a cmux core change.

When cmux supervises the process, the scanner copies
`CMUX_PLUGIN_GENERATION` into each event. This lets the core retire an old
process generation without removing observations from a replacement process.

The manifests are derived from herdr at commit
`7b675f42af35508eab66ac42fe1598628597a893` under Apache-2.0. See
`manifests/LICENSE`, `manifests/README.md`, and `ATTRIBUTIONS.md`.

The host gives each plugin generation an owned process boundary. Keep any
helper processes in the inherited Unix process group, or they may outlive the
plugin if they call `setsid`.

The generation fence protects journal state when a stopped process writes late.
It does not remove the normal Unix process-group identifier reuse race, so the
host treats process identity as authoritative only when the platform reports a
current foreground group. A userland plugin must use its own generation and
idempotency keys for every event.

The package performs native foreground process-group inspection on Linux and
macOS. On other platforms it uses the public one-process response from cmux,
so runtime wrappers and child-process matching have reduced coverage there.

The plugin manager stages the artifact and selected configuration with a local
rollback guard. They are separate filesystem transactions, so a power loss
between the two writes can leave a mismatched old/new pair. Startup validation
and a later explicit update repair that state.

On Linux, hosts that do not expose a controlling-terminal foreground group can
opt in to herdr-compatible child-group inference with
`CMUX_AGENT_PROCESS_DETECTION=child-groups` (the legacy
`HERDR_PROCESS_DETECTION=child-groups` name is also accepted). The mode picks
the newest direct child process group and is disabled by default because the
kernel cannot prove which child is foreground in that situation. The scanner
fails closed after 64 direct-child probes.
