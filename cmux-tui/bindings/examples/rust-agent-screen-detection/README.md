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

The package performs native foreground process-group inspection on Linux and
macOS. On other platforms it uses the public one-process response from cmux,
so runtime wrappers and child-process matching have reduced coverage there.
