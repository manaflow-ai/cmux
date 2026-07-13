# cmux-tui SDK releases

The cmux-tui SDKs share one version and one going-forward tag:

```bash
cmux-sdk-vX.Y.Z
```

Historical releases used `mux-sdk-vX.Y.Z`; the publish workflows still accept
that prefix so old release history remains connected. These tags are separate
from app release tags such as `vX.Y.Z`. Current SDK package versions are
`0.1.0`.

## One-time registry setup

- PyPI: create or claim the `cmux` project, then add a trusted publisher for
  `manaflow-ai/cmux`, workflow `.github/workflows/sdk-publish-python.yml`, and
  environment `pypi`. The workflow uses OIDC trusted publishing and PyPI
  attestations, so no PyPI token is stored in GitHub.
- crates.io: publish or claim the first `cmux-client` crate release manually if
  crates.io still requires an initial release, then add a trusted publisher for
  owner `manaflow-ai`, repo `cmux`, workflow
  `.github/workflows/sdk-publish-crates.yml`, and environment `crates-io`. The
  workflow exchanges GitHub OIDC for a short-lived crates.io token via
  `rust-lang/crates-io-auth-action`.
- npm: configure trusted publishing and required 2FA policy for package `cmux`,
  workflow `.github/workflows/sdk-publish-npm.yml`, and environment `npm`.
  Warning: the live npm package name `cmux` is currently a different cloud-VM CLI
  package. Publishing the SDK to that name is a deliberate coordinated breaking
  move; the npm workflow never publishes on tag push and requires manual
  `workflow_dispatch` with `confirm_npm_cmux: true`.
- Maven Central: verify the `com.cmux` namespace in Central Portal, add complete
  Maven metadata, configure GPG signing, and decide the Central publishing
  workflow. Java publishing is intentionally a CI stub until those prerequisites
  are done.
- Go: there is no registry publish step. Once the tag exists, users can install
  with `go get github.com/manaflow-ai/cmux/cmux-tui/bindings/go@cmux-sdk-vX.Y.Z`.

## Cutting a release

1. Update all SDK manifests to the same version:
   `cmux-tui/bindings/typescript/package.json`,
   `cmux-tui/bindings/python/pyproject.toml`, and
   `cmux-tui/bindings/rust/Cargo.toml`.
2. Run the cmux-tui binding tests locally or wait for `.github/workflows/cmux-tui.yml` on
   the release PR. The publish workflows also run the language conformance gate
   before publishing.
3. Merge the version bump.
4. Create and push the namespaced SDK tag:

   ```bash
   git tag cmux-sdk-vX.Y.Z
   git push origin cmux-sdk-vX.Y.Z
   ```

5. Watch the SDK workflows. Python and Rust publish automatically after their
   conformance gates pass. Go validates only. Java reports the Maven Central
   TODO. npm validates on tag push but does not publish until a maintainer runs
   `sdk publish npm` manually with `confirm_npm_cmux: true`.

## Safety checks

Each SDK workflow is triggered by `cmux-sdk-v*` tags, legacy `mux-sdk-v*` tags,
or `workflow_dispatch`. The version guard extracts `X.Y.Z` from the tag, or uses
the manual `version` input, and fails unless the TypeScript, Python, and Rust
package manifest versions all match.

Publish jobs use least-privilege permissions. OIDC-capable registries use
`id-token: write` only on the publish job. No long-lived registry tokens are
committed or required for PyPI, crates.io, or npm trusted publishing. PyPI uses
PEP 740 attestations; npm publishes with provenance. All GitHub Actions `uses:`
entries are pinned to full commit SHAs.
