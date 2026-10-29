# CmuxProductAnalytics

The macOS product analytics catalog and emitter. Every product event the Mac
app sends is a case of `ProductAnalyticsEvent`; `ProductAnalytics` queues it
off the calling thread, deduplicates, derives funnel events, merges the shared
context and hands it to an `AnalyticsEmitting` sink. The app's sink forwards to
the PostHog SDK it already embeds, which owns batching and the offline queue.

The sink is `AnalyticsEmitting` from `CMUXMobileCore`, the seam the iOS
emitter uses, so both apps share one analytics vocabulary.

The event catalog, the questions each event answers and the insights built on
them are documented in [docs/posthog/mac-product-analytics.md](../../../docs/posthog/mac-product-analytics.md).

## Testing

```swift
let sink = RecordingAnalyticsSink()
let analytics = ProductAnalytics(
    isEnabled: true,
    sink: sink,
    ledger: ProductAnalyticsLedger(defaults: UserDefaults(suiteName: "test")!),
    context: ProductAnalyticsContext(appVersion: "1.0", appBuild: "1", channel: "dev", osVersion: "15.0")
)
analytics.track(.signInStarted)
await analytics.drain()
#expect(sink.events.map(\.name).contains("cmux_sign_in_started"))
```

`ProductAnalytics(isEnabled: false, ...)` and `ProductAnalytics.disabled`
enqueue nothing.

```bash
swift test --package-path Packages/macOS/CmuxProductAnalytics
```
