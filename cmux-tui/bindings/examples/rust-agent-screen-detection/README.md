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

The plugin uses the public Rust SDK. This source-tree reference pins the
matching `cmux-sdk` release as its contract and uses a path dependency while
that SDK is unreleased in this checkout. A standalone plugin repository must
either keep a matching SDK checkout at the same relative path or remove the
`path` field after the SDK release is available. Its build command uses Cargo's
`--locked` mode, so installation does not rewrite the checked-in dependency
graph. It registers a namespaced journal
producer, reads terminal process metadata and viewport text, and appends
`cmux.agent-plugin.v1` events. A different implementation can use Python,
another language, or a different ruleset without a cmux core change.

The supervisor must provide a non-blank `CMUX_PLUGIN_ID`. The executable exits
when that namespace is absent; it never invents a shared producer ID. The
manager generates and persists this value for the installed package, while a
hand-written configuration must set `agents.plugin.id` explicitly.

Process identity uses executable and wrapper arguments before reading
`CMUX_AGENT` or `HERDR_AGENT` from the host process environment. The hint is a
fallback for wrappers that hide their executable, which keeps normal scans
cheap and avoids treating a globally inherited hint as stronger than visible
process evidence. Runtime parsing handles attached eval and module flags and
stops at the first positional script. Shell parsing handles direct script
arguments and escaped command words. Command flags follow the grammar of the
specific shell, including fish's separate and inline `--command` forms, while
value-taking, no-exec, exit-only, and unknown shell modes fail closed. For
runtimes that document an attached form, the option value stays with its
option, so it cannot hide the following script. Unsupported spellings fail
closed. A package-shaped path inside eval text cannot claim an agent identity.

When cmux supervises the process, the scanner copies
`CMUX_PLUGIN_GENERATION` into each event. This lets the core retire an old
process generation without removing observations from a replacement process.

The manifests are derived from herdr at manifest snapshot commit
`2290257acb2085ce6842ba5c7e3ca50c3ba64f02` under Apache-2.0. The adapted
detector engine follows source reference commit
`7b675f42af35508eab66ac42fe1598628597a893`. The Claude manifest includes the
upstream background-shell correction from
`987b070fbfa187e85009b45cd7e208fc6175ff6a`. See
`manifests/LICENSE`, `manifests/README.md`, and `ATTRIBUTIONS.md`. The
Manaflow portions use MIT; the package includes that text in `LICENSE-MIT`.
The checked-in `manifests/SHA256SUMS` record is verified before the bundled
rules compile. It catches accidental edits to vendored bytes. It is not a
release signature, so an explicit remote update still needs signed catalog
verification before remote content is trusted.

The host gives each plugin generation an owned process boundary. Keep any
helper processes in the inherited Unix process group, or they may outlive the
plugin if they call `setsid`.

The generation fence protects journal state when a stopped process writes late.
It does not remove the normal Unix process-group identifier reuse race, so the
host treats process identity as authoritative only when the platform reports a
current foreground group. The scanner commits an edge only after journal
admission. A transport result with an uncertain outcome keeps the exact event
envelope and idempotency key, then retries it with bounded backoff; a definite
admission failure rolls the in-memory edge back so a later scan can try again.
A userland plugin must use its own generation and idempotency keys for every
event.

The reference package currently targets macOS and Linux. Its Rust SDK
transport is Unix-only, and its native process backends cover macOS and Linux.
A Windows publication needs a Windows-capable SDK transport and process
backend. Do not list Windows in `cmux-plugin.toml` until those pieces exist.

Manifest loading is bounded before parsing: a set can contain at most 256
active manifests, a cache or override directory can contain at most 512
entries, and each manifest is limited to 256 KiB. Rule and matcher limits are
also enforced by the manifest validator.

The selected plugin configuration is limited to 4 MiB and registry metadata to
16 KiB before JSON parsing. On Linux, process files are streamed through a
128 KiB limit before parsing; an oversized file fails closed and
leaves name-based detection available when possible.

The plugin manager stages the artifact and selected configuration with a local
rollback guard. They are separate filesystem transactions, so a power loss
between the two writes can leave a mismatched old/new pair. Startup validation
and a later explicit update repair that state.

The manager bounds one installed-plugin root to 256 filesystem entries. This
includes hidden transaction files and registry metadata, so stale install debris
cannot turn a list or selector operation into an unbounded scan. Remove stale
entries before retrying an operation that reports this limit.

Git install and update sources are passed to `git` as process arguments. The
manager rejects HTTP and HTTPS user information, query strings, and fragments
to keep passwords and tokens out of process listings. Use a Git credential
helper or an SSH key for private repositories. SSH user names, SCP-like sources,
and local paths remain supported. Git metadata output is capped at 16 KiB before
the manager parses it; overflow is treated as unavailable.

The daemon keeps OSC title and progress as generic terminal metadata and may
retain them across a process change. The scanner records the output revision at
each identity edge and ignores those fields until a later revision proves that
the new process produced output. Older daemons that never expose revisions use
the startup-grace compatibility path. If a host has supplied a generation
anchor and later omits its revision, the scanner fails closed until a newer
revision is available. A local screen hash may schedule a read when the host
does not expose a revision, but it is never used as a generation fence. Exit
fencing uses only the host revision supplied for that exit; an exit without an
anchor keeps the old-host compatibility path rather than comparing unrelated
tokens.

On Linux, hosts that do not expose a controlling-terminal foreground group can
opt in to herdr-compatible child-group inference with
`CMUX_AGENT_PROCESS_DETECTION=child-groups` (the legacy
`HERDR_PROCESS_DETECTION=child-groups` name is also accepted). The mode picks
the newest direct child process group and is disabled by default because the
kernel cannot prove which child is foreground in that situation. The scanner
fails closed after 64 direct-child probes.
