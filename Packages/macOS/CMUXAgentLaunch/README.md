# CMUXAgentLaunch

CMUXAgentLaunch owns agent launch, resume, fork, and live-process inspection primitives that do not depend on the cmux app lifecycle.

Use `AgentProcessArgumentsParser` with captured `KERN_PROCARGS2` bytes in tests:

```swift
let parser = AgentProcessArgumentsParser()
let arguments = parser.argumentsAndEnvironment(fromKernProcArgs: bytes)
```
