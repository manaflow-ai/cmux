# cmux SDK releases

The public release set contains four language packages at one version:

| Language | Distribution | Release ref |
| --- | --- | --- |
| Rust | crates.io `cmux-client` and `cmux-sidebar` | `cmux-sdk-vX.Y.Z` |
| Go | module `github.com/manaflow-ai/cmux/cmux-tui/bindings/go` | `cmux-tui/bindings/go/vX.Y.Z` |
| TypeScript | npm `cmux-sdk` | `cmux-sdk-vX.Y.Z` |
| Python | PyPI `cmux-sdk` with import package `cmux` | `cmux-sdk-vX.Y.Z` |

Java, C++, and Zig remain source bindings with package and conformance tests.
Their metadata does not gate these four releases.

## CLI package isolation

The npm and PyPI names `cmux` belong exclusively to the prebuilt TUI launcher.
`npx cmux` and `uvx cmux` therefore keep installing the CLI. SDK consumers use:

```bash
npm install cmux-sdk
python -m pip install cmux-sdk
```

Do not publish SDK contents through `tui-publish-npm.yml` or
`tui-publish-pypi.yml`.

All packages target mux protocol 10 and expose the same generated command and
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
only to mint the short-lived token used for the atomic push.

- npm: the package must exist before npm allows a trusted publisher. Create the
  `npm-bootstrap` GitHub environment with a temporary `NPM_BOOTSTRAP_TOKEN`
  secret, then dispatch `sdk-bootstrap-npm` once:

  ```bash
  gh api --method POST repos/manaflow-ai/cmux/dispatches \
    -f event_type=sdk-bootstrap-npm \
    -F 'client_payload[confirm_bootstrap]=true'
  ```

  The workflow tests and packs `0.0.0-bootstrap.0` on
  a GitHub-hosted runner, publishes that exact artifact with provenance under
  the `bootstrap` tag, and refuses to claim `latest`. Configure repository
  `manaflow-ai/cmux`, workflow `sdk-release-cut.yml`, and the `npm` environment
  as the trusted publisher. In the package's **Settings > Publishing access**,
  select **Require two-factor authentication and disallow tokens**. This still
  permits the trusted publisher. Then revoke the npm access token and delete
  the `NPM_BOOTSTRAP_TOKEN` environment secret. Keep `1.0.0` unpublished for the
  coordinated OIDC release. Every release verifies the npm bootstrap
  provenance from `.github/workflows/sdk-bootstrap-npm.yml` on `main` and
  requires npm user `lawrencechen` to remain the sole package maintainer. A
  rerun after an ambiguous bootstrap publish accepts only the exact tested
  archive with matching provenance.
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

  The workflow installs Cargo 1.95.0, tests and packages the source-controlled
  minimal crate outside the Git checkout, and publishes byte-checked
  `cmux-sidebar` `0.0.0-bootstrap.0`. It never consumes stable version `1.0.0`.
  Configure a trusted publisher for `cmux-sidebar` with owner `manaflow-ai`,
  repository `cmux`, workflow `sdk-release-cut.yml`, environment `crates-io`.
  On its crate settings page, enable **Require trusted publishing for all new
  versions**. Configure the same publisher for existing crate `cmux-client` and
  enable **Require trusted publishing for all new versions** there too. Then
  revoke the crates.io API token and delete the `CARGO_BOOTSTRAP_TOKEN`
  environment secret. Both crates must have the sole crates.io owner
  `lawrencecchen` (owner ID `431397`) and repository
  `https://github.com/manaflow-ai/cmux`; the release gate verifies that exact
  state and rejects either crate while API-token publishing remains enabled.
- Go: no registry account is required. The module becomes available when the
  path-prefixed semantic-version tag is pushed.

The npm and PyPI `cmux-sdk` names and the crates.io `cmux-sidebar` name were
unclaimed when this release path was created. Reserve npm with
`sdk-bootstrap-npm.yml`, PyPI with `sdk-bootstrap-pypi.yml`, and crates.io with
`sdk-bootstrap-crates.yml` before cutting release tags. The release preflight
verifies the npm bootstrap provenance, the attested PyPI `0.0.0a0` bootstrap,
and exact crates.io ownership plus trusted-publishing-only state.

## Cutting a release

1. Update the TypeScript, Python, `cmux-client`, and `cmux-sidebar` manifests to
   the same `X.Y.Z`. Keep the `cmux-sidebar` dependency on `cmux-client` pinned
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
unpublished `cmux-client` archive patched in locally before any tag is created.
The OIDC-enabled jobs package with `--no-verify`, require an exact digest match
with those archives, and publish with `--no-verify`, so package and dependency
code runs only in the credential-free preflight.

The Python build pins `build`, `setuptools`, and `wheel`, disables build
isolation, and installs both the exact wheel and source distribution as clean
consumers before either artifact is uploaded.

The workflow next downloads the public Go module through the normal proxy and
checksum database, retrying propagation for up to 30 minutes before it compiles
clean consumers of both its root and `raw` packages. It publishes npm, the PyPI
wheel, and the PyPI source distribution in separate jobs while publishing
`cmux-client` before `cmux-sidebar`. Each
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

The cut workflow holds one cross-version concurrency lock until the Go check and
all registry jobs finish. If one publish job fails, use GitHub's **Re-run failed
jobs** action so successful crates, Python distributions, npm packages, and the
tag step are not repeated.

## Verification after publishing

Use clean temporary projects with no repository-relative dependencies:

```bash
cargo add cmux-client@X.Y.Z
cargo add cmux-sidebar@X.Y.Z
cargo tree -p cmux-sidebar@X.Y.Z --depth 1 | grep -F 'cmux-client vX.Y.Z'
go get github.com/manaflow-ai/cmux/cmux-tui/bindings/go@vX.Y.Z
npm install cmux-sdk@X.Y.Z
python -m pip install cmux-sdk==X.Y.Z
```

Also verify `npx cmux --version` and `uvx cmux --version` still resolve the TUI
launcher release rather than an SDK artifact.

## Safety checks

The cut workflow refuses non-`main` dispatches, mismatched manifest versions,
release tags that point to another commit, or package names other than
`cmux-sdk`. It pushes both release tags atomically after Go validation.
Publisher jobs use least-privilege permissions. npm, PyPI, and crates.io
authenticate with short-lived OIDC credentials. PyPI emits PEP 740 attestations
and npm publishes provenance. Stable npm and crates.io packages reject API-token
publishing. GitHub Actions are pinned to full commit SHAs.
