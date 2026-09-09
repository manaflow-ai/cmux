# CmuxHive

Mac-to-Mac directory, pairing, and viewer-session state. App composition injects
registry, presence, scoped pairing storage, transport, and deadline dependencies;
the package tests do not launch the application.

## Identity and route selection

Device identity uses `cmxCanonicalDeviceID` from `CMUXMobileCore`: UUID casing is
canonical, while opaque non-UUID identifiers retain their exact bytes. Registry,
pairing, presence updates, and viewer ownership use this same identity contract.

`HiveViewerRoutePolicy(allowsLoopbackRoutes:)` is shared by row presentation,
pairing, and the viewer runtime. Release policy excludes development loopback
routes. A supported route kind is not authenticated peer admission; production
Tailscale admission remains fail-closed.

## Testing lifecycle ownership

Mirror route replacement has its own cancellation owner, independent of the
obsolete observer it tears down. The application transfers mirror ownership
before teardown and cancels pending replacements on detach or window close.

The package exposes an injected readiness deadline so tests can deliver events
without polling or settling sleeps:

```swift
@Test @MainActor func firstWorkspaceIsReady() async {
    let readiness = HiveMirrorWorkspaceReadiness()
    let deadline = AsyncStream<Void>.makeStream()
    defer { readiness.finish(); deadline.continuation.finish() }
    let workspaceID = UUID()
    readiness.publish(workspaceID)
    let result = await readiness.wait {
        for await _ in deadline.stream { break }
    }
    #expect(result == workspaceID)
}
```

Run `swift test` in this package on a leased remote Mac, or use the hosted
`swift-package-tests` CI job. These tests cover the domain and cancellation
seams; live two-Mac listing, viewing, input, reconnect, and native focus require
separate authenticated end-to-end verification.
