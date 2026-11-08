# cmux SDK releases

The public release set contains four language packages at one version:

| Language | Distribution | Release ref |
| --- | --- | --- |
| Rust | crates.io `cmux-sdk` and `cmux-sidebar` | `cmux-sdk-vX.Y.Z` |
| Go | module `github.com/manaflow-ai/cmux/cmux-tui/bindings/go` | `cmux-tui/bindings/go/vX.Y.Z` |
| TypeScript | npm `cmux-sdk` | `cmux-sdk-vX.Y.Z` |
| Python | PyPI `cmux-sdk` with import package `cmux` | `cmux-sdk-vX.Y.Z` |

Java, C++, and Zig remain source bindings with package and conformance tests.
Their metadata does not gate these four releases.

The historical crates.io `cmux-client` 0.1.x package is outside this release
set. Do not publish new versions from this repository; Rust users install
`cmux-sdk` and import crate `cmux`.

## CLI package isolation

The npm and PyPI names `cmux` belong exclusively to the prebuilt TUI launcher.
`npx cmux` and `uvx cmux` therefore keep installing the CLI. SDK consumers use:

```bash
npm install cmux-sdk
python -m pip install cmux-sdk
```

Do not publish SDK contents through `tui-publish-npm.yml` or
`tui-publish-pypi.yml`.

## Raw-binary manifest contract

Release artifacts that are consumed as raw binaries must describe each file in
the `runtimeByBinary` manifest. Do not infer compatibility from a package-wide
Linux claim. Every file entry records its operating system, architecture, and
libc explicitly, for example `os: linux`, `architecture: x86_64`, and
`libc: glibc` or `libc: musl`. macOS entries use `os: macos` and their actual
architecture and `libc: none`; Windows entries use `os: windows`, their actual
architecture, and `libc: none`.

The runtime matcher accepts compatibility aliases at the manifest boundary:
`amd64` and `x64` map to `x86_64`, `arm64` maps to `aarch64`, and Linux
`gnu`/`linux-gnu` map to `glibc` while `musl`/`linux-musl` map to `musl`.
Emit the canonical values in new manifests, and retain aliases only when
reading older manifests. A Linux raw binary with `libc: musl` must not be
advertised as a glibc binary, and a `libc: glibc` entry must state its tested
minimum where the binary requires one.

The `manylinux` and `musllinux` wheel tags follow the Python Packaging
Authority platform-tag specifications. They are package-specific claims for
the PyPI wheel files, not defaults for raw release binaries. Preserve the
existing package contract: the TUI PyPI Linux wheels contain static musl
binaries and publish matching `manylinux` and `musllinux` tags. Do not add a
global `glibc >= 2.28` requirement to this manifest; retain that requirement
only for the package or runtime path that actually enforces it.

All packages target mux protocol 12 and expose the same generated command and
event catalogs. The release preflight rejects runtime inventory drift and stale
generated layers for all four publish targets before it runs their shared
wire-behavior conformance suite.

## One-time registry setup

Establish release authority before adding registry credentials:

1. Create a dedicated SDK release GitHub App with repository Contents
   read/write permission and install it only on `manaflow-ai/cmux`.
2. Create the credential-free `sdk-release` approval environment. Configure
   protected branches only, require a reviewer other than the dispatcher,
   prevent self-review, and disable administrator bypass.
3. Create the `sdk-release-credentials` environment for protected branches
   only. Store the App client ID as `SDK_RELEASE_APP_CLIENT_ID` and its private
   key as `SDK_RELEASE_APP_PRIVATE_KEY`. Do not add registry credentials or
   expose this environment to another workflow job.
4. Apply the same protected-branch, reviewer, self-review, and bypass policy to
   `crates-io`, `npm`, `pypi`, `crates-bootstrap`, `npm-bootstrap`, and
   `pypi-bootstrap`. A branch workflow must never obtain a registry credential
   or trusted-publisher OIDC identity.
5. Add an active tag ruleset that restricts creation, update, and deletion of
   `refs/tags/cmux-sdk-v*` and
   `refs/tags/cmux-tui/bindings/go/v*`. Grant bypass only to the SDK release
   GitHub App. The repository workflow token and repository writers must not
   bypass this ruleset.

The privileged workflows use `repository_dispatch`, so GitHub loads their
definitions and source revision from the default branch. The `sdk-release`
approval gates credential-free final revalidation. A fresh GitHub-hosted job
then checks that the remote ref snapshot is unchanged, prepares the two tags
without checking out repository files, and accesses `sdk-release-credentials`
only to mint the short-lived token used for the atomic push. The approved
authorization is valid for the same workflow run attempt and 15 minutes.

- npm: the package must exist before npm allows a trusted publisher. Create the
  `npm-bootstrap` GitHub environment with a temporary `NPM_BOOTSTRAP_TOKEN`
  secret, then dispatch `sdk-bootstrap-npm` once:

  ```bash
  gh api --method POST repos/manaflow-ai/cmux/dispatches \
    -f event_type=sdk-bootstrap-npm \
    -F 'client_payload[confirm_bootstrap]=true'
  ```

  A credential-free job tests and packs `0.0.0-bootstrap.0`, then uploads the
  exact archive. A fresh job downloads and digest-checks that archive before
  its final step receives the temporary token. That step disables npm
  lifecycle scripts, publishes with provenance under the `bootstrap` tag, and
  cannot claim `latest`. A separate credential-free job reconciles the exact
  archive and provenance after an ambiguous publish result. Configure repository
  `manaflow-ai/cmux`, workflow `sdk-release-cut.yml`, and the `npm` environment
  as the trusted publisher. In the package's **Settings > Publishing access**,
  select **Require two-factor authentication and disallow tokens**. This still
  permits the trusted publisher. Then revoke the npm access token and delete
  the `NPM_BOOTSTRAP_TOKEN` environment secret. Keep `1.0.0` unpublished for the
  coordinated OIDC release. Every release verifies the npm bootstrap
  provenance from `.github/workflows/sdk-bootstrap-npm.yml` on `main` and
  requires npm user `lawrencechen` to remain the sole package maintainer. A
  **Re-run all jobs** after an ambiguous bootstrap result. The credential-free
  preflight skips publication only for the exact tested archive with matching
  provenance. After the stable SDK is live, remove the obsolete `sdk` dist-tag
  from the CLI package with `npm dist-tag rm cmux sdk`; `latest` remains the
  `npx cmux` launcher.
- PyPI: create the `pypi-bootstrap` GitHub environment, then add a pending
  trusted publisher for project `cmux-sdk`, repository `manaflow-ai/cmux`,
  workflow `sdk-bootstrap-pypi.yml`, environment `pypi-bootstrap`. Dispatch it
  once:

  ```bash
  gh api --method POST repos/manaflow-ai/cmux/dispatches \
    -f event_type=sdk-bootstrap-pypi \
    -F 'client_payload[confirm_bootstrap]=true'
  ```

  It tests and
  publishes the attested prerelease `0.0.0a0`, which creates the project and
  reserves its name before release tags can exist. Then add repository
  `manaflow-ai/cmux`, workflow `sdk-release-cut.yml`, environment `pypi` as a
  trusted publisher for stable releases. The sole PyPI owner `lawrencecchen`
  must run the bootstrap; the release gate rejects any role or organization
  change.
- crates.io: create the `crates-bootstrap` GitHub environment with a temporary,
  short-lived `CARGO_BOOTSTRAP_TOKEN` secret, then dispatch the ownership
  bootstrap once:

  ```bash
  gh api --method POST repos/manaflow-ai/cmux/dispatches \
    -f event_type=sdk-bootstrap-crates \
    -F 'client_payload[confirm_bootstrap]=true'
  ```

  A credential-free job installs Cargo 1.95.0, tests the source-controlled
  minimal `cmux-sdk` and `cmux-sidebar` crates, and uploads their packaged
  archives. Fresh serialized jobs check each archive digest and allowlisted
  paths, reconstruct the original manifest, and prove Cargo reproduces the
  exact bytes. Their final steps receive the temporary token and publish with
  package verification disabled, so crate code never runs beside the
  credential. Credential-free decisions keep reconciled crates out of the
  protected publishing environment. A separate credential-free matrix
  reconciles both uploads after every publish attempt, even when the other
  crate's job fails. The bootstrap uses `0.0.0-bootstrap.0` for both crates
  and preserves stable version `1.0.0`.
  **Re-run all jobs** after a failed or ambiguous bootstrap result so the
  credential-free registry preflight decides whether another publish is safe.
  Configure trusted publishers for `cmux-sdk` and `cmux-sidebar` with owner
  `manaflow-ai`, repository `cmux`, workflow `sdk-release-cut.yml`, environment
  `crates-io`. On the `cmux-sdk` crate settings page, enable **Require trusted
  publishing for all new versions**. Enable **Require trusted publishing for
  all new versions** on `cmux-sidebar` too. Then
  revoke the crates.io API token and delete the `CARGO_BOOTSTRAP_TOKEN`
  environment secret. Both crates must have the sole crates.io owner
  `lawrencecchen` (owner ID `431397`) and repository
  `https://github.com/manaflow-ai/cmux`; the release gate verifies that exact
  state and rejects either crate while API-token publishing remains enabled.
- Go: no registry account is required. The module becomes available when the
  path-prefixed semantic-version tag is pushed.

The npm and PyPI `cmux-sdk` names and the crates.io `cmux-sdk` and
`cmux-sidebar` names were unclaimed when this release path was created. Reserve
npm with `sdk-bootstrap-npm.yml`, PyPI with `sdk-bootstrap-pypi.yml`, and both
crates with `sdk-bootstrap-crates.yml` before cutting release tags. The release
preflight verifies the npm bootstrap provenance, the attested PyPI `0.0.0a0`
bootstrap, and exact crates.io ownership plus trusted-publishing-only state.

## Cutting a release

1. Update the TypeScript, Python, `cmux-sdk`, and `cmux-sidebar` manifests to
   the same `X.Y.Z`. Keep the `cmux-sidebar` dependency on `cmux-sdk` pinned
   to that exact version. Go follows the path-prefixed tag. The version must be
   greater than every existing `cmux-sdk-v*` release. Major versions are limited
   to 0 and 1 until the Go module path adopts a `/vN` suffix.
2. Verify the publish set:

   ```bash
   python3 cmux-tui/bindings/check-versions.py \
     --published-only \
     --expected X.Y.Z
   ```

3. Merge the version and release-path changes to `main`.
4. Dispatch the release from a checkout with repository write access:

   ```bash
   gh api --method POST repos/manaflow-ai/cmux/dispatches \
     -f event_type=sdk-release-cut \
     -F 'client_payload[version]=X.Y.Z' \
     -F 'client_payload[confirm_publish]=true'
   ```

The cut workflow verifies current protected `main`, then runs Rust, Go,
TypeScript, and Python package and live-conformance preflights in parallel
against that exact commit. The TypeScript and Python preflights retain the
validated registry artifacts, and the Rust preflight retains both verified
crate archives. A credential-free registry preflight then requires each target
version to be missing or byte-identical and usable. It also verifies that this
repository's trusted publisher created the exact PyPI bootstrap files. Only
then does the workflow create `cmux-sdk-vX.Y.Z` and
`cmux-tui/bindings/go/vX.Y.Z` atomically on the same commit. After approval, an
unprivileged job repeats artifact, registry-history, ownership, and
existing-provenance checks, including the exact npm source commit, then records
the validated remote ref snapshot. A fresh minimal job rejects any snapshot
change before it mints the tag-only App token and pushes. An approval delay
therefore cannot make the preflight authority stale or let a newer release
overtake it, and mutable validation code never shares a runner with the App
private key.

The Rust preflight uses the same pinned Cargo version as publishing. It packages
both crates and tests the extracted `cmux-sidebar` archive with the extracted
unpublished `cmux-sdk` archive patched in locally before any tag is created.
The OIDC-enabled jobs package with `--no-verify`, require an exact digest match
with those archives, and publish with `--no-verify`, so package and dependency
code runs only in the credential-free preflight.

The Python build pins `build`, `setuptools`, and `wheel`, disables build
isolation, and installs both the exact wheel and source distribution as clean
consumers before either artifact is uploaded. Those clean installs must include
the PEP 561 `py.typed` marker.

The workflow next downloads the public Go module through the normal proxy and
checksum database, retrying propagation for up to 30 minutes. It compares a
deterministic manifest of that downloaded tree with the exact release commit,
then compiles clean consumers of both its root and `raw` packages. It publishes
npm, the PyPI
wheel, and the PyPI source distribution in separate jobs while publishing
`cmux-sdk` before `cmux-sidebar`. Each
irreversible write has its own rerunnable job. Every job requires the exact
latest release tag, verifies that its commit is on protected `main`, and binds
provenance to that commit. Manual publisher dispatches validate only and cannot
write to a registry. Before publishing or recovering a failed publish, the
workflow checks the registry digest and skips only an artifact whose bytes
exactly match the validated local package. PyPI reconciliation also rejects
unexpected or yanked files while allowing the expected wheel and source
distribution to arrive in either order. Crates.io reconciliation rejects
yanked versions. npm, PyPI, and crates.io reconciliation prevent releases older
than active registry history, and npm requires the requested version to own the
`latest` distribution tag. Registry transport interruptions are retried within
the configured reconciliation deadline. If stable npm or PyPI artifacts already
exist, the pretag gate also requires their trusted-publisher provenance to name
`sdk-release-cut.yml` on `main` and the expected registry environment. A final
job repeats those provenance checks for the exact npm archive, wheel, and source
distribution after every publisher finishes.
Crates.io metadata and ownership checks share a contact-bearing client paced to
one API request per second. Immutable `.crate` bytes come from
`static.crates.io`, not the registry API.

The cut workflow holds one cross-version concurrency lock until the Go check and
all registry jobs finish. If tag creation fails before both coordinated tags
exist, use GitHub's **Re-run all jobs** action so approval-fresh registry checks
run again. A failed-job retry accepts the exact coordinated tag post-state when
an atomic push succeeded but its response was lost. Recovery also permits
protected `main` to advance when all other release tags still match the final
revalidation snapshot and the release commit remains an ancestor of current
`main`; otherwise it rejects stale authorization. After tag creation succeeds,
use **Re-run failed jobs** for a publisher failure so successful registry writes
are not repeated.

## Verification after publishing

Use clean temporary projects with no repository-relative dependencies:

```bash
cargo add cmux-sdk@X.Y.Z
cargo add cmux-sidebar@X.Y.Z
cargo tree -p cmux-sidebar@X.Y.Z --depth 1 | grep -F 'cmux-sdk vX.Y.Z'
go get github.com/manaflow-ai/cmux/cmux-tui/bindings/go@vX.Y.Z
npm install cmux-sdk@X.Y.Z
python -m pip install cmux-sdk==X.Y.Z
```

Also verify `npx cmux --version` and `uvx cmux --version` still resolve the TUI
launcher release rather than an SDK artifact.

## Safety checks

The cut workflow refuses non-`main` dispatches, mismatched manifest versions,
release tags that point to another commit, or unexpected registry package
names. It pushes both release tags atomically after Go validation.
Publisher jobs use least-privilege permissions. npm, PyPI, and crates.io
authenticate with short-lived OIDC credentials. PyPI emits PEP 740 attestations
and npm publishes provenance. Stable npm and crates.io packages reject API-token
publishing. GitHub Actions are pinned to full commit SHAs.
