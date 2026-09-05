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

`CodexWriterRestorePreflight` consumes final argv, environment, and actual cwd.
Tests create temporary homes and hold their own nonblocking `flock`; they never
use a real conversation or remove a provider-owned lock. Inject `ownerLookup`
to model a release during discovery, and use `mappedSurface(in:)` to check
ambiguous runtime candidates without AppKit. Production continuation requires
an active lock, a complete single-holder scan, current process ancestry and
kernel TTY, then a second process/runtime-generation check before focus.

```swift
let result = CodexWriterRestorePreflight().inspect(
    sessionID: fixtureThreadID,
    arguments: ["codex", "resume", fixtureThreadID],
    environment: ["CODEX_HOME": fixtureHome.path],
    workingDirectory: fixtureProject.path,
    fallbackHome: fixtureUserHome.path
)
```

The probe releases its own descriptor before launch. Codex remains the final
atomic lock authority for later races. A local actor cannot replace this
cross-process kernel check. CLI execution stays synchronous for `execve`;
Vault awaits bounded inspection off the main actor. Unknown owners, remote
providers, and uninspectable legacy shell commands never trigger guessed focus,
lock deletion, process termination, or an implicit fork.
