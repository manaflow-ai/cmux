#if DEBUG
import Dispatch
import Testing
@testable import CmuxControlSocket

/// Behavior coverage for the byte-faithful lift of `TerminalController`'s
/// per-command debug-log classifier (begin/end gating, command-token
/// classification + sanitization, and the top-level JSON status scan).
@Suite("ControlSocketCommandLog")
struct ControlSocketCommandLogTests {
    @Test func loggingEnabledParsesTruthyValues() {
        for value in ["1", "true", "TRUE", "yes", "On", " true "] {
            let log = ControlSocketCommandLog(
                environment: [ControlSocketCommandLog.logEnabledEnvironmentKey: value]
            )
            #expect(log.isLoggingEnabled, "expected \(value) to enable logging")
        }
    }

    @Test func loggingDisabledForFalsyOrMissing() {
        #expect(!ControlSocketCommandLog(environment: [:]).isLoggingEnabled)
        for value in ["0", "false", "no", "off", "maybe", ""] {
            let log = ControlSocketCommandLog(
                environment: [ControlSocketCommandLog.logEnabledEnvironmentKey: value]
            )
            #expect(!log.isLoggingEnabled, "expected \(value) to disable logging")
        }
    }

    @Test func classifiesV2JSONByMethod() {
        let log = ControlSocketCommandLog(environment: [:])
        let info = log.info(forCommand: "  {\"method\":\"window.list\",\"id\":1}  ")
        #expect(info.protocolName == "v2")
        #expect(info.commandKey == "window.list")
    }

    @Test func classifiesV1ByFirstToken() {
        let log = ControlSocketCommandLog(environment: [:])
        let info = log.info(forCommand: "list_windows extra args")
        #expect(info.protocolName == "v1")
        #expect(info.commandKey == "list_windows")
    }

    @Test func emptyCommandFallsBackToSanitizedPlaceholder() {
        // The empty first token defaults to "<empty>", which the sanitizer then
        // rewrites ("<"/">" are disallowed) to "_empty_" — faithful to legacy.
        let log = ControlSocketCommandLog(environment: [:])
        #expect(log.info(forCommand: "   ").commandKey == "_empty_")
    }

    @Test func nonJSONWithBraceMethodMissingIsV1() {
        // hasPrefix("{") but not valid JSON-with-method -> falls to v1 branch,
        // first token sanitized.
        let log = ControlSocketCommandLog(environment: [:])
        let info = log.info(forCommand: "{not json")
        #expect(info.protocolName == "v1")
    }

    @Test func sanitizesDisallowedCharactersAndCaps() {
        #expect(ControlSocketCommandLog.sanitizedToken("a b/c") == "a_b_c")
        #expect(ControlSocketCommandLog.sanitizedToken("ok.method-1:2_3") == "ok.method-1:2_3")
        #expect(ControlSocketCommandLog.sanitizedToken("") == "<empty>")
        let long = String(repeating: "x", count: 200)
        #expect(ControlSocketCommandLog.sanitizedToken(long).count == 96)
    }

    @Test func statusErrorForV1ErrorPrefix() {
        #expect(ControlSocketCommandLog.status(forResponse: "ERROR: nope") == "error")
    }

    @Test func statusErrorForTopLevelErrorKey() {
        #expect(ControlSocketCommandLog.status(forResponse: "{\"error\":{\"code\":\"x\"}}") == "error")
    }

    @Test func statusErrorForOkFalse() {
        #expect(ControlSocketCommandLog.status(forResponse: "{\"ok\":false}") == "error")
    }

    @Test func statusOkForOkTrue() {
        #expect(ControlSocketCommandLog.status(forResponse: "{\"ok\":true,\"result\":{}}") == "ok")
    }

    @Test func statusOkSkipsNestedErrorKey() {
        // A nested (non-top-level) "error" key must not be treated as an error.
        #expect(ControlSocketCommandLog.status(forResponse: "{\"result\":{\"error\":1},\"ok\":true}") == "ok")
    }

    @Test func statusOkForPlainOk() {
        #expect(ControlSocketCommandLog.status(forResponse: "PONG") == "ok")
    }

    @Test func endMessageSkippedWhenFastQuietAndOk() {
        let log = ControlSocketCommandLog(environment: [:], slowThresholdMs: 1_000_000)
        let info = SocketCommandDebugInfo(protocolName: "v1", commandKey: "ping")
        let message = log.endMessageIfNeeded(
            info: info,
            startedAtUptimeNanos: DispatchTime.now().uptimeNanoseconds,
            response: "PONG",
            loggingEnabled: false
        )
        #expect(message == nil)
    }

    @Test func endMessageEmittedOnError() {
        let log = ControlSocketCommandLog(environment: [:], slowThresholdMs: 1_000_000)
        let info = SocketCommandDebugInfo(protocolName: "v1", commandKey: "ping")
        let message = log.endMessageIfNeeded(
            info: info,
            startedAtUptimeNanos: 0,
            response: "ERROR: boom",
            loggingEnabled: false
        )
        #expect(message?.contains("status=error") == true)
        #expect(message?.hasPrefix("socket.command.end proto=v1 method=ping") == true)
    }

    @Test func endMessageEmittedWhenLoggingEnabled() {
        let log = ControlSocketCommandLog(environment: [:], slowThresholdMs: 1_000_000)
        let info = SocketCommandDebugInfo(protocolName: "v2", commandKey: "window.list")
        let message = log.endMessageIfNeeded(
            info: info,
            startedAtUptimeNanos: 0,
            response: "{\"ok\":true}",
            loggingEnabled: true
        )
        #expect(message?.contains("status=ok") == true)
    }

    @Test func beginMessageFormat() {
        let log = ControlSocketCommandLog(environment: [:])
        let info = SocketCommandDebugInfo(protocolName: "v2", commandKey: "x.y")
        #expect(log.beginMessage(for: info) == "socket.command.begin proto=v2 method=x.y")
    }
}
#endif
