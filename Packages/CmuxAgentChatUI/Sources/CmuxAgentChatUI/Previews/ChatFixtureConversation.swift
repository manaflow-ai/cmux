import CmuxAgentChat
import Foundation

/// Builds the demo conversation used by previews and the app's debug
/// screen: a realistic "fix a failing test" coding session exercising every
/// ``ChatMessageKind``.
public struct ChatFixtureConversation {
    /// Creates a fixture conversation builder.
    public init() {}

    /// Builds the fixture transcript and its session descriptor.
    ///
    /// - Parameter now: The anchor for message timestamps; the conversation
    ///   ends shortly before this instant so date headers show "Today".
    /// - Returns: The scripted messages (ascending seq) and a matching
    ///   descriptor whose agent is working.
    public func make(now: Date = Date()) -> ([ChatMessage], ChatSessionDescriptor) {
        var builder = Builder(start: now.addingTimeInterval(-1380))

        builder.add(.system, .status(ChatStatusTransition(event: .sessionStarted)))
        builder.add(
            .user,
            .prose(
                ChatProse(
                    text: "CI is red on main: ChatStoreTests/testReconnectResync keeps failing. Can you find the bug and fix it?"
                )
            )
        )
        builder.add(
            .agent,
            .thought(
                ChatThought(
                    text: "The test name suggests the stream-drop resync path. I should reproduce the failure first, then read the store's run loop and check how the tail resync merges missed messages after a reconnect."
                )
            ),
            gap: 8
        )
        builder.add(
            .agent,
            .prose(
                ChatProse(
                    text: """
                    I'll reproduce the failure first, then inspect the resync path in `ChatConversationStore`.

                    ## Plan
                    - Reproduce the **flaky** reconnect failure
                    - Read the store's `run()` loop
                    - Check how the tail resync merges missed messages

                    > The test asserts `rows.count == 5` after a stream drop.

                    Docs: https://github.com/manaflow-ai/cmux
                    """
                )
            ),
            gap: 6
        )
        builder.add(
            .agent,
            .toolUse(
                ChatToolUse(
                    toolName: "Read",
                    summary: "Read Tests/ChatStoreTests.swift",
                    inputDetail: "file_path: Tests/ChatStoreTests.swift\nlimit: 120",
                    output: "120 lines read. testReconnectResync drops the stream, emits two missed messages, then asserts rows.count == 5.",
                    status: .succeeded
                )
            ),
            gap: 14
        )
        builder.add(
            .agent,
            .toolUse(
                ChatToolUse(
                    toolName: "Grep",
                    summary: "Grep resyncTail in Sources/",
                    inputDetail: "pattern: resyncTail\npath: Sources/",
                    output: "Sources/Store/ChatConversationStore.swift:212: private func resyncTail() async {",
                    status: .succeeded
                )
            ),
            gap: 9
        )
        builder.add(
            .agent,
            .terminal(
                ChatTerminalCapture(
                    command: "swift test --filter ChatStoreTests/testReconnectResync",
                    output: """
                    Building for debugging...
                    Build complete! (4.31s)
                    Test Suite 'ChatStoreTests' started.
                    Test Case 'testReconnectResync' started.
                    XCTAssertEqual failed: ("3") is not equal to ("5")
                    missed messages were not merged after stream drop
                    Test Case 'testReconnectResync' failed (0.041 seconds).
                    Test Suite 'ChatStoreTests' failed.
                    Executed 1 test, with 1 failure (0 unexpected)
                    error: fatalError
                    """,
                    exitCode: 1,
                    durationSeconds: 6.8,
                    isRunning: false
                )
            ),
            gap: 22
        )
        builder.add(
            .agent,
            .prose(
                ChatProse(
                    text: "Reproduced. `resyncTail()` filters missed messages with `seq >` but compares against the **pre-drop** tail captured before the await, so messages appended during the fetch are skipped. I'll re-read the tail after the await."
                )
            ),
            gap: 16
        )
        builder.add(
            .agent,
            .fileEdit(
                ChatFileEdit(
                    filePath: "Sources/Store/ChatConversationStore.swift",
                    operation: .edit,
                    additions: 12,
                    deletions: 4,
                    unifiedDiff: """
                    @@ -210,11 +210,19 @@ extension ChatConversationStore {
                         private func resyncTail() async {
                    -        guard let newestKnown = messages.last?.seq else { return }
                             let page = try await source.history(
                                 sessionID: descriptor.id,
                                 beforeSeq: nil,
                                 limit: pageSize
                             )
                    +        guard let newestKnown = messages.last?.seq else {
                    +            messages = page.messages
                    +            hasMoreHistory = page.hasMore
                    +            reproject()
                    +            return
                    +        }
                             let missed = page.messages.filter { $0.seq > newestKnown }
                    -        messages.append(contentsOf: missed)
                    +        if !missed.isEmpty {
                    +            appendToWindow(missed)
                    +        }
                    """
                )
            ),
            gap: 30
        )
        builder.add(
            .agent,
            .permissionRequest(
                ChatPermissionRequest(
                    title: "Claude wants to run:",
                    subject: "swift test --filter ChatStoreTests",
                    resolution: .approved
                )
            ),
            gap: 10
        )
        builder.add(
            .agent,
            .terminal(
                ChatTerminalCapture(
                    command: "swift test --filter ChatStoreTests",
                    output: """
                    Building for debugging...
                    Build complete! (2.02s)
                    Test Suite 'ChatStoreTests' started.
                    Executed 7 tests, with 0 failures (0 unexpected) in 0.310 seconds
                    """,
                    exitCode: 0,
                    durationSeconds: 4.2,
                    isRunning: false
                )
            ),
            gap: 26
        )
        builder.add(
            .agent,
            .prose(
                ChatProse(
                    text: """
                    All green. The fix re-anchors the tail after the await:

                    ```swift
                    let missed = page.messages.filter { $0.seq > newestKnown }
                    if !missed.isEmpty {
                        appendToWindow(missed)
                    }
                    ```

                    `appendToWindow` also enforces the window cap, so a long disconnect can no longer grow the window unbounded.
                    """
                )
            ),
            gap: 14
        )
        builder.add(
            .user,
            .attachment(
                ChatAttachment(
                    media: .image,
                    displayName: "ci-failure.png",
                    hostPath: "/tmp/cmux-attachments/ci-failure.png"
                )
            ),
            gap: 35
        )
        builder.add(
            .user,
            .prose(
                ChatProse(
                    text: "Here's the CI screenshot from the other failing job, same root cause?"
                )
            ),
            gap: 4
        )
        builder.add(
            .agent,
            .question(
                ChatQuestion(
                    prompt: "That job also runs the flaky integration suite. How should I handle it?",
                    options: [
                        ChatQuestion.Option(
                            label: "Fix in this PR",
                            detail: "Apply the same re-anchor fix to the integration store"
                        ),
                        ChatQuestion.Option(
                            label: "Separate PR",
                            detail: "Land the unit fix now, follow up for integration"
                        ),
                    ],
                    selectedOptionLabel: "Separate PR"
                )
            ),
            gap: 18
        )
        builder.add(
            .system,
            .status(
                ChatStatusTransition(event: .contextCompacted, detail: "78k → 12k tokens")
            ),
            gap: 12
        )
        builder.add(
            .agent,
            .toolUse(
                ChatToolUse(
                    toolName: "WebFetch",
                    summary: "WebFetch ci.example.com/runs/8412",
                    inputDetail: "url: https://ci.example.com/runs/8412",
                    output: "HTTP 404: run expired from retention",
                    status: .failed
                )
            ),
            gap: 11
        )
        builder.add(
            .agent,
            .permissionRequest(
                ChatPermissionRequest(
                    title: "Claude wants to run:",
                    subject: "git push origin fix-reconnect-resync",
                    resolution: nil
                )
            ),
            gap: 9
        )
        builder.add(
            .agent,
            .question(
                ChatQuestion(
                    prompt: "Commit message style for the fix?",
                    options: [
                        ChatQuestion.Option(label: "fix: resync tail after reconnect"),
                        ChatQuestion.Option(
                            label: "Detailed body",
                            detail: "One-line subject plus a body explaining the race"
                        ),
                    ],
                    selectedOptionLabel: nil
                )
            ),
            gap: 6
        )
        builder.add(
            .agent,
            .toolUse(
                ChatToolUse(
                    toolName: "Task",
                    summary: "Task: audit other awaits racing window state",
                    inputDetail: "prompt: scan store methods for stale anchors across awaits",
                    output: nil,
                    status: .running
                )
            ),
            gap: 7
        )
        builder.add(
            .system,
            .unsupported(ChatUnsupportedPayload(rawType: "usage_report")),
            gap: 5
        )

        let descriptor = ChatSessionDescriptor(
            id: "fixture-session",
            agentKind: .claude,
            title: "Fix failing reconnect test",
            workspaceID: "ws-demo",
            terminalID: "term-demo",
            workingDirectory: "~/dev/cmux",
            state: .working(since: now.addingTimeInterval(-45)),
            lastActivityAt: now
        )
        return (builder.messages, descriptor)
    }

    /// Accumulates fixture messages with monotonic seq and timestamps.
    private struct Builder {
        var messages: [ChatMessage] = []
        private var time: Date
        private var seq = 0

        init(start: Date) {
            self.time = start
        }

        mutating func add(_ role: ChatRole, _ kind: ChatMessageKind, gap: TimeInterval = 20) {
            time = time.addingTimeInterval(gap)
            messages.append(
                ChatMessage(
                    id: "fixture-\(seq)",
                    seq: seq,
                    role: role,
                    timestamp: time,
                    kind: kind
                )
            )
            seq += 1
        }
    }
}
