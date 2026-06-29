# CmuxMobileShellUI

The SwiftUI half of the cmux iOS shell.

This is the leaf UI layer extracted out of the `cmuxFeature` catch-all target. It
owns the workspace shell, sign-in, pairing, terminal detail, and root routing
views, plus the iOS push coordinator that the root view injects into the
SwiftUI environment.

It depends only downward: the decomposed domain facade
(`CmuxMobileShell.CMUXMobileShellStore`), the core/value packages
(`CMUXMobileCore`, `CmuxMobileShellModel`, `CmuxMobileWorkspace`,
`CmuxMobileSupport`), `CmuxAuthRuntime` for the injected `AuthCoordinator`,
`CmuxMobileTerminal` for the libghostty surface, and `CmuxMobileCamera` for the
QR-pairing capture stack. It never reaches into RPC/transport concretes.

`cmuxFeature` now sits *above* this package as the composition root
(`CMUXMobileRootScene`, `CMUXMobileRuntime`, the auth/push wiring) and
re-exports the package so the app shell keeps `import cmuxFeature` working.

## Entry points

- ``CMUXMobileAppView`` — the live mobile UI root, mounted by `CMUXMobileRootScene`.
- ``MobilePushCoordinator`` — APNs↔store bridge, constructed at the app root.
