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

## GUI shell commands

`GuiShellSession` owns a persistent noninteractive zsh process for a GUI pane.
The native pane captures its working directory and routing environment at creation;
`execute(command:requestID:)` returns bounded combined output, exit status, and
shell cwd. Apply that cwd through the workspace's directory-report path and pass it
on the next agent turn. Stable request IDs prevent completed retries from running
commands twice. Commands receive closed stdin; interactive terminal applications
are outside this command-composer interface. Call `cancel(requestID:)` to stop a
command, or `close()` when destroying its pane.

Package tests use temporary directories and an explicit `HOME`/`PATH`, including
compound `cd`, quoted directories, exports, failures, duplicate requests, bounded
output, deadlines, and shell exit/recovery. They do not need cmux or GUI access.
