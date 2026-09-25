# CmuxAgentHooks

`CmuxAgentHooks` contains the pure prompt lifecycle policy shared by cmux hook
adapters. The executable owns persistence and maps its session records into the
value type exposed here.

```swift
import CmuxAgentHooks

var state = AgentHookPromptLifecycleState()
state.beginAuthoritativePrompt(turnID: "turn-1")
state.endAuthoritativePrompt()
```

The package has no AppKit, CLI, filesystem, or process dependencies, so its
state transitions can be tested with `swift test --package-path
Packages/macOS/CmuxAgentHooks` from the repository root, independently of the
cmux application.
