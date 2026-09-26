# CmuxAgentHooks

Dependency-free managed-agent hook contracts and classification. The package
keeps provider stop parsing and its behavioral tests outside the app and CLI
targets; presentation and notification policy remain in the composition root.

## API

- `AgentHookAbnormalStopClass` — stable, provider-neutral failure categories.
- `AgentHookAbnormalStopClassifier` — bounded stop-signal and cancellation
  classification with fail-closed handling for ordinary prose and sensitive
  provider diagnostics.

## Testing

The test target is headless and has no app or filesystem dependencies:

```bash
swift test --package-path Packages/macOS/CmuxAgentHooks
```
