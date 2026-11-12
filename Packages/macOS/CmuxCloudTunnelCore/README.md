# Cloud tunnel lifecycle

The NetworkExtension provider sends start/stop requests synchronously into one
`AsyncStream`. `CloudTunnelProviderStartGate.run()` consumes them on its actor,
coalesces identical starts, waits for startup before teardown, and rejects new
starts once the provider is retiring. Every adapter completion carries the
start generation so an old callback cannot finish a newer request.

The callback API is limited to the Apple/WireGuard bridge. Adapter calls return
immediately, allowing the actor to receive stop requests during startup. Tests
inject an adapter whose completion events are controlled explicitly, so they
exercise ordering without sleeps, AppKit, system VPN access, or credentials.

```swift
let lifecycle = CloudTunnelProviderStartGate(adapter: adapter)
let consumer = Task { await lifecycle.run() }
lifecycle.start(configuration: .success(savedConfiguration)) { error in
    // Complete the corresponding NetworkExtension request.
}
lifecycle.stop { /* Complete after teardown. */ }
await consumer.value
```

Run `swift test --package-path Packages/macOS/CmuxCloudTunnelCore`. The app-host
test target also compiles the same test source against the package product.
