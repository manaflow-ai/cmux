# CmuxCloudBannerCore

`CmuxCloudBannerCore` owns the Foundation-only Cloud banner persistence and
the pure optional VPN-state projection used by the macOS app. The dismissal
repository reloads the current defaults map before every read-modify-write, so
independent live clients cannot erase each other's entries.

Run its focused tests directly with SwiftPM:

```bash
swift test --package-path Packages/macOS/CmuxCloudBannerCore
```
