# CMUXAgentLaunch

CMUXAgentLaunch owns agent launch, resume, fork, and live-process inspection primitives that do not depend on the cmux app lifecycle.

Use `AgentProcessArgumentsParser` with captured `KERN_PROCARGS2` bytes in tests:

```swift
let parser = AgentProcessArgumentsParser()
let arguments = parser.argumentsAndEnvironment(fromKernProcArgs: bytes)
```

Build a process scan from app-owned projections:

```swift
let selector = AgentProcessCandidateSelector(
    processes: candidates,
    policy: policy,
    launchExecutableMatcher: AgentLaunchExecutableMatcher()
)
var scan = AgentProcessArgumentScan(
    processes: candidates,
    selector: selector,
    injectedArgumentsProvider: nil,
    processArgumentBytesProvider: readProcessBytes,
    processArgumentsDecoder: decodeProcessArguments,
    additionalMetadataRequiresFullDecode: { _ in false }
)
let arguments = scan.arguments(for: processID)
```
