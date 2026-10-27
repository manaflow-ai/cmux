# CMUXMobileCore

Shared protocol seams and value types used by both the iOS and macOS apps.
Higher-level mobile packages depend on this package instead of importing one
another for shared contracts.

## Testing telemetry consent

Pass a suite name so tests do not read or mutate the user's preferences:

```swift
let defaults = UserDefaults(suiteName: "example.telemetry-test")!
let consent = UserDefaultsAnalyticsConsentProvider(suiteName: "example.telemetry-test")

defaults.set(true, forKey: UserDefaultsAnalyticsConsentProvider.telemetryKey)
#expect(consent.isTelemetryEnabled)
```
