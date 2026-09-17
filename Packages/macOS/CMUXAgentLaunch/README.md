# CMUXAgentLaunch

`CMUXAgentLaunch` owns launch, restore, and environment policy for coding
agents. New value-level policy APIs accept captured inputs directly, while
executable targets keep process mutation at their own seams.

## Testing Claude Teams respawn transport

Construct a transport with an explicit environment dictionary, then inspect the
decoded value without launching cmux or mutating the test process:

```swift
let transport = ClaudeTeamsRespawnEnvironmentTransport()
let encoded = transport.encodedValue(from: [
    "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
    "CLAUDE_CONFIG_DIR": "/tmp/claude-config",
])
let decoded = transport.decodedEnvironment(from: encoded)
```

The transport applies `AgentLaunchEnvironmentPolicy` while encoding and again
while decoding, so tests can also prove that credentials and process identity
fail closed at the transport boundary.

## Testing executable search paths

`AgentExecutableSearchPathResolver` accepts a deterministic directory probe, so
relative-path traversal and malformed scalar cases can be tested without
touching the host filesystem:

```swift
let resolver = AgentExecutableSearchPathResolver(
    currentDirectoryPath: "/tmp/project",
    directoryExists: { ["/tmp/project/bin"].contains($0) }
)
let directories = resolver.normalizedDirectories(from: ["missing/..", "bin"])
// ["/tmp/project/bin"]
```

## Testing Codex durable-state resolution

Codex home selection and durable verification take captured values and an
injected file manager, so tests never need the developer's real `~/.codex`:

```swift
let home = CodexHomeResolver().resolve(
    launchEnvironment: ["HOME": "/tmp/captured-user"],
    launchWorkingDirectory: "/tmp/project",
    ambientEnvironment: ["CODEX_HOME": "/tmp/current-codex"],
    fallbackHomeDirectory: "/tmp/fallback-user"
)
let results = CodexSessionResumeVerifier().verifyBatch(
    [CodexSessionResumeVerificationRequest(sessionId: checkpointID)],
    codexHome: home,
    fileManager: fixtureFileManager
)
```

## Testing Codex writer ownership

`CodexWriterLockInspector` probes an injected account path and exact thread UUID.
Tests create disposable lock files and hold `flock` from an independent descriptor;
no Codex process, app, or real account is required. The probe coordinates with
Codex's `.coordination.lock` when present and never creates or removes provider files.

```swift
let preflight = CodexWriterRestorePreflight()
try preflight.waitUntilAvailable(
    delays: [0.1, 0.2],
    sleep: { _ in /* release the fixture lock here */ },
    inspect: {
        CodexWriterLockInspector().inspect(sessionID: fixtureThreadID, codexHome: fixtureHome)
    }
)
```

The CLI waits before claiming a binding and checks again without waiting at exec.
The probe is advisory: Codex remains the final atomic authority. An active lock
never authorizes process termination. Process descriptor inspection supplies
best-effort diagnostic candidates only, not proof of flock ownership.
