# CmuxAgentPromptCore

`CmuxAgentPromptCore` owns bounded workspace FIFO admission for addressed
agent prompts. The target terminal records prompt identity and hook attribution
in `TerminalPromptInputLedger`; this package owns only delivery ordering.

```swift
@MainActor
let service = AgentPromptSubmissionService()
let receipt = service.submit(
    workspaceID: workspaceID,
    requestedSurfaceID: surfaceID,
    text: prompt,
    delivery: { messageID in
        deliverCompoundPrompt(prompt, messageID: messageID)
    }
)
```

The delivery closure must pass the supplied `messageID` into the target
surface's compound prompt transaction. Hook confirmation should use the
ledger's returned `PromptSubmissionConfirmation` and then call
`service.confirm(workspaceID:surfaceID:messageID:)` in the same main-actor
transition.
