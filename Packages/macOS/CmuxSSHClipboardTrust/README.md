# CmuxSSHClipboardTrust

Owns persistent, endpoint-scoped SSH clipboard-write grants and projection ownership lookup. The app injects one main-actor store into terminal views and workspace lifecycle code. Ghostty callbacks consume a separate synchronized permission snapshot; they never access this store.

The grant permits OSC 52 writes only. Clipboard reads remain denied by this policy. Cloud mirrors retain their existing provider grant.

Tests inject an isolated defaults suite and run without the app host:

```swift
let defaults = UserDefaults(suiteName: "clipboard-test-\(UUID())")!
let store = SSHClipboardWriteTrustStore(defaults: defaults)
store.setTrusted(true, for: .ssh("endpoint-digest"))
```

Run `swift test --package-path Packages/macOS/CmuxSSHClipboardTrust`.
