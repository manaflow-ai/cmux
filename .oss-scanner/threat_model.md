# cmux scanner guidance

cmux is a macOS terminal with an embedded browser, local automation, SSH remote
terminals, iOS access and a Cloud dashboard. It runs shells and coding agents
with the user's authority. Treat terminal output, remote hosts, webpages,
filenames and repository metadata as untrusted input.

Read `/src/SECURITY.md` and `/src/docs/security/threat-model.md` first. That
threat model maps assets, trust boundaries and source anchors. Its requirements
are review guidance, not proof that controls work.

## Build and coverage

The working tree is at `/src`. The Dockerfile builds `/usr/local/bin/cmuxd-remote`,
runs its Go tests, and installs root, web and webviews JavaScript dependencies
from their lockfiles. Git object storage is omitted; the scanner records the
cloned revision before building. Native macOS/iOS apps require Xcode and Apple
services, so they cannot be built in this Linux image. Their source remains in
scope, and findings requiring Apple-platform reproduction must say so. Rust/Zig
targets and Git submodules are source-only in this image.

Rerun the portable tests offline with:

```sh
cd /src/daemon/remote
GOPROXY=off GOTOOLCHAIN=local go test ./... -count=1 -timeout=180s
```

Do not use production credentials, databases, Cloud VMs or deployed services.
Use mocks and synthetic fixtures. Full web integration and native app tests are
not claimed to pass here.

## Review priorities

- Terminal escape sequences, paste, filenames, branch names, repository config
  and agent output must not become commands, clipboard writes, URL opens or
  browser privilege without user consent.
- Check local socket modes and authorization in `Packages/macOS/CmuxControlSocket`
  and `Packages/macOS/CmuxSettings`.
- Check SSH/CLI relay authorization and object scoping in `daemon/remote` and
  `Packages/macOS/CmuxRemoteWorkspace`. Authentication alone is not authorization.
- Check device pairing, identity proof, replay, revocation and admission in
  `Packages/Shared/CmuxIrohTransport` and `Packages/iOS`.
- Trace account/team authorization through `web/app/api` and `web/services` for
  VM operations, terminal attachment and publications. Current cmux Cloud uses
  PlanetScale Postgres.
- Check browser origins, redirects, destination validation, proxying, credential
  exposure, logs, updates and privileged helpers.

The desktop app is not an OS sandbox for commands, approved agents or shell
configuration. A compromised user account or OS is outside the boundary. That
does not excuse remote-to-local, cross-user, cross-workspace or cross-tenant
access. Prioritize unauthorized execution, credential theft, Cloud escapes and
update/helper privilege escalation. Reports should include entry point,
prerequisites, demonstrated impact, a safe reproducer, and unavailable platform
verification.
