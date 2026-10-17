import Foundation
import Testing
import CmuxConversation
@testable import CmuxConversationHost

@Suite struct ProcessConversationTransportTests {
    @Test func matchesReplyWithoutConsumingServerRequestWithSameID() async throws {
        let script = #"read -r request; printf '%s\n' '{"id":"one","method":"approval","params":{}}' '{"id":"one","result":{"ok":true}}'; read -r keepalive"#
        let transport = try await ProcessConversationTransport.open(executable: "/bin/sh", arguments: ["-c", script], workingDirectory: nil)
        let response = try await transport.send(.object(["id": .string("one"), "method": .string("request")]))
        #expect(response?.objectValue?["ok"] == .bool(true))
        var iterator = transport.messages.makeAsyncIterator()
        #expect(try await iterator.next()?.objectValue?["method"] == .string("approval"))
        await transport.close()
    }

    @Test func nativeRejectionIsNotReportedAsSuccessfulWrite() async throws {
        let script = #"read -r request; printf '%s\n' '{"id":"one","error":{"code":-32602,"message":"private diagnostics"}}'; read -r keepalive"#
        let transport = try await ProcessConversationTransport.open(executable: "/bin/sh", arguments: ["-c", script], workingDirectory: nil)
        do {
            _ = try await transport.send(.object(["id": .string("one"), "method": .string("request")]))
            Issue.record("A rejected native request must throw")
        } catch let error as ConversationProviderError {
            #expect(error == .rejected("The provider rejected the request"))
            #expect(!error.description.contains("private diagnostics"))
        }
        await transport.close()
    }

    @Test func timeoutDoesNotReplayCommand() async throws {
        let transport = try await ProcessConversationTransport.open(executable: "/bin/sh", arguments: ["-c", "read -r request; read -r keepalive"], workingDirectory: nil, timeout: .milliseconds(20))
        do {
            _ = try await transport.send(.object(["id": .string("one"), "method": .string("request")]))
            Issue.record("Missing response must be uncertain")
        } catch let error as ConversationProviderError {
            #expect(error.description.contains("uncertain"))
        }
        await transport.close()
    }

    @Test func stalledInputCannotBlockTheReplyDeadline() async throws {
        // The stopped child holds stdin open without reading. A frame larger
        // than the pipe must still time out and release the actor.
        let transport = try await ProcessConversationTransport.open(
            executable: "/bin/sh", arguments: ["-c", "kill -STOP $$"],
            workingDirectory: nil, timeout: .milliseconds(40)
        )
        do {
            _ = try await transport.send(.object([
                "id": .string("blocked"), "method": .string("request"),
                "params": .string(String(repeating: "x", count: 1_048_576)),
            ]))
            Issue.record("A child that stops reading must not block the transport")
        } catch let error as ConversationProviderError {
            #expect(error.description.contains("uncertain"))
        }
        await transport.close()
    }

    @Test func remoteArgumentsQuoteEmbeddedShellCharacters() {
        #expect(ProcessConversationTransportFactory.shellQuote("a'b $(touch nope)") == "'a'\"'\"'b $(touch nope)'")
    }
}
