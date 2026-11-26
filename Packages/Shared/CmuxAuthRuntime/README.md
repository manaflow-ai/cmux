# CmuxAuthRuntime

Shared (iOS + macOS) auth orchestration layered over `CMUXAuthCore`.

This package lifts the auth god class out of the iOS-only `CmuxMobileAuth` into
an injected, testable runtime so both apps share one orchestrator, one error
vocabulary, and one config resolver. No singletons: every collaborator is
constructed at the app composition root and injected.

## Types

- `AuthCoordinator` — `@MainActor @Observable` orchestrator owning
  `isAuthenticated` / `currentUser` / `isLoading` / `isRestoringSession`,
  sequencing sign-in (Apple / Google / email code / debug `42`) plus session
  restore + validation. Init-injected token client, persistence stores,
  presentation anchor, config, and launch options.
- `AuthClient` — backend seam. `StackAuthClient` is the production conformer over
  `StackClientApp`.
- `AuthPresentationAnchoring` — OAuth presentation-anchor seam.
  `AuthPresentationContextProvider` is the default conformer.
- `AuthConfig` — resolved Stack credentials + callback URL + API base URL.
  `resolve(environment:overrides:)` applies `LocalConfig.plist` overrides
  supplied by the caller (the type never reads `Bundle.main`).
- `AuthError` — the shared localized error vocabulary.
- `AuthErrorMapper` — pure backend-error → `AuthError` translation.
- `AuthLaunchOptions` — launch-time priming inputs (UI-test fixtures, dev-auth).

## Testing

Construct the coordinator with fakes; no AppKit/UIKit boot required:

```swift
let store = FakeKeyValueStore()
let coordinator = AuthCoordinator(
    client: FakeAuthClient(user: someUser),
    sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
    userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
    anchor: FakeAnchor(),
    config: .test,
    launch: .plain(),
    isOnline: { true }
)
try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
#expect(coordinator.isAuthenticated)
```
