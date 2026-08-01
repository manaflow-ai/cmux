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

## One-time registry setup

- npm: the package must exist before npm allows a trusted publisher. Publish the
  first `cmux-sdk` release interactively from the merged release commit, then
  configure repository `manaflow-ai/cmux`, workflow `sdk-release-cut.yml`, and
  allow `npm publish`. Keep the GitHub environment named `npm`.
- PyPI: add a pending trusted publisher for project `cmux-sdk`, repository
  `manaflow-ai/cmux`, workflow `sdk-release-cut.yml`, environment `pypi`.
- crates.io: configure trusted publishers for existing crate `cmux-client` with
  owner `manaflow-ai`, repository `cmux`, workflow `sdk-release-cut.yml`,
  environment `crates-io`. crates.io requires a manual first release for a new
  crate, so publish `cmux-sidebar` interactively once, then add the same trusted
  publisher configuration for subsequent releases.
- Go: no registry account is required. The module becomes available when the
  path-prefixed semantic-version tag is pushed.

The npm and PyPI `cmux-sdk` names and the crates.io `cmux-sidebar` name were
unclaimed when this release path was created. Recheck them immediately before
the first publish. PyPI can claim its name through the pending publisher; npm
and crates.io require the interactive bootstrap above.

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
4. Run `.github/workflows/sdk-release-cut.yml` from `main` with `version=X.Y.Z`
   and `confirm_publish=true`.

The cut workflow verifies current protected `main`, then runs Rust, Go,
TypeScript, and Python package and live-conformance preflights in parallel
against that exact commit. The TypeScript and Python preflights retain the
validated registry artifacts. Only after all four preflights pass does the
workflow create `cmux-sdk-vX.Y.Z` and `cmux-tui/bindings/go/vX.Y.Z` atomically
on the same commit.

The workflow next resolves the public Go module from a clean consumer. It then
publishes npm, the PyPI wheel, and the PyPI source distribution in separate
jobs while publishing `cmux-client` before `cmux-sidebar`. Each irreversible
write has its own rerunnable job. Every job requires the exact latest release
tag, verifies that its commit is on protected `main`, and binds provenance to
that commit. Manual publisher dispatches validate only and cannot write to a
registry. Before publishing or recovering a failed publish, the workflow checks
the registry digest and skips only an artifact whose bytes exactly match the
validated local package.

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
and npm publishes provenance. GitHub Actions are pinned to full commit SHAs.
