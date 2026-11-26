import CmuxControlSocket
import Testing

@Suite("Socket command line framing")
struct SocketCommandLineTests {
    // MARK: Per-session PID-key argument encoding

    @Test func pidKeyAcceptsExpectedIdentifierCharset() {
        #expect(SocketCommandLine.agentHookPIDKeyArgument(
            statusKey: "codex",
            sessionId: "0199fbe2-6a4b-7c31-9d5e-2f4a8b61c703"
        ) == "codex.0199fbe2-6a4b-7c31-9d5e-2f4a8b61c703")
        #expect(SocketCommandLine.agentHookPIDKeyArgument(
            statusKey: "hermes-agent",
            sessionId: "default"
        ) == "hermes-agent.default")
        #expect(SocketCommandLine.agentHookPIDKeyArgument(
            statusKey: "opencode",
            sessionId: "ses_41:part.2"
        ) == "opencode.ses_41:part.2")
    }

    @Test func pidKeyRejectsLineFeedSessionId() {
        #expect(SocketCommandLine.agentHookPIDKeyArgument(
            statusKey: "codex",
            sessionId: "abc\nset_agent_pid codex.default 999 --tab=t1"
        ) == nil)
    }

    @Test func pidKeyRejectsCarriageReturnSessionId() {
        #expect(SocketCommandLine.agentHookPIDKeyArgument(
            statusKey: "codex",
            sessionId: "abc\rclear_agent_pid codex.default --tab=t1"
        ) == nil)
    }

    @Test func pidKeyRejectsTokenizerMetacharacters() {
        for hostile in [
            "abc\u{00}def",
            "abc def",
            "abc\tdef",
            "abc\"def",
            "abc'def",
            "abc\\def",
            "abc=def",
            "abc--def\u{2028}",
        ] {
            #expect(
                SocketCommandLine.agentHookPIDKeyArgument(statusKey: "codex", sessionId: hostile) == nil,
                "expected rejection for session id \(hostile.debugDescription)"
            )
        }
    }

    @Test func pidKeyRejectsEmptyAndOverlongSessionIds() {
        #expect(SocketCommandLine.agentHookPIDKeyArgument(statusKey: "codex", sessionId: "") == nil)
        let overlong = String(repeating: "a", count: 257)
        #expect(SocketCommandLine.agentHookPIDKeyArgument(statusKey: "codex", sessionId: overlong) == nil)
        let maximal = String(repeating: "a", count: 256)
        #expect(SocketCommandLine.agentHookPIDKeyArgument(
            statusKey: "codex",
            sessionId: maximal
        ) == "codex.\(maximal)")
    }

    @Test func pidKeyRejectsUnsafeStatusKey() {
        #expect(SocketCommandLine.agentHookPIDKeyArgument(
            statusKey: "codex x",
            sessionId: "default"
        ) == nil)
        #expect(SocketCommandLine.agentHookPIDKeyArgument(
            statusKey: "codex\n",
            sessionId: "default"
        ) == nil)
    }

    // MARK: Framing guard

    @Test func framedLineTerminatesSafeCommandExactlyOnce() {
        #expect(SocketCommandLine.framedLine(
            for: "clear_agent_pid codex.abc --tab=t1 --clear-status"
        ) == "clear_agent_pid codex.abc --tab=t1 --clear-status\n")
    }

    @Test func framedLineRefusesEmbeddedLineFeed() {
        #expect(SocketCommandLine.framedLine(
            for: "clear_agent_pid codex.abc\nset_agent_pid codex.default 999 --tab=t1"
        ) == nil)
    }

    @Test func framedLineRefusesEmbeddedCarriageReturnAndNul() {
        #expect(SocketCommandLine.framedLine(for: "ping\rpong") == nil)
        #expect(SocketCommandLine.framedLine(for: "ping\u{00}pong") == nil)
        #expect(SocketCommandLine.framedLine(for: "ping\r\npong") == nil)
    }

    @Test func framedLineAllowsEscapedQuotedPayloads() {
        // socketQuote-style escaping keeps multi-line user text on one wire
        // line; the guard must accept the escaped form.
        #expect(SocketCommandLine.framedLine(
            for: #"input_text "line one\nline two" --tab=t1"#
        ) == "input_text \"line one\\nline two\" --tab=t1\n")
    }

    // MARK: End-to-end property for the hook sinks

    @Test func hostileSessionIdCannotProduceSecondCommand() {
        for hostile in [
            "abc\nset_agent_pid codex.default 999 --tab=t1",
            "abc\rset_agent_pid codex.default 999 --tab=t1",
            "abc\r\nset_agent_pid codex.default 999 --tab=t1",
        ] {
            // Rejection before framing: the per-session PID key is never composed.
            #expect(SocketCommandLine.agentHookPIDKeyArgument(
                statusKey: "codex",
                sessionId: hostile
            ) == nil)
            // Framing guard: even a raw splice of the same session id cannot be
            // framed onto the wire as a payload carrying a second command.
            let rawSplice = "clear_agent_pid codex.\(hostile) --clear-status"
            #expect(SocketCommandLine.framedLine(for: rawSplice) == nil)
        }
    }
}
