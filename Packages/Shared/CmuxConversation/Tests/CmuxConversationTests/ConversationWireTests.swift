import Foundation
import Testing
@testable import CmuxConversation

@Suite struct ConversationWireTests {
    @Test func providerNumericRequestIdentitiesSurviveBothDirections() throws {
        let source = Data(#"{"id":18446744073709551615,"signed":-9223372036854775808,"ordinary":9007199254740993,"ratio":0.1234567890123456789012345678901234567}"#.utf8)
        let value = try JSONDecoder().decode(ConversationJSONValue.self, from: source)
        let encoded = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(ConversationJSONValue.self, from: encoded) == value)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("18446744073709551615"))
        #expect(text.contains("9007199254740993"))
        #expect(text.contains("0.1234567890123456789012345678901234567"))
    }

    @Test func invalidNumbersCannotSilentlyBecomeStrings() {
        for value in ["NaN", "Infinity", "12invalid", ""] {
            #expect(throws: (any Error).self) {
                _ = try JSONEncoder().encode(ConversationJSONValue.number(value))
            }
        }
    }

    @Test func stringAndNumericNativeIDsRemainDifferent() throws {
        let value = try JSONDecoder().decode(ConversationJSONValue.self, from: Data(#"["123",123,"false",false,null]"#.utf8))
        #expect(value == .array([.string("123"), .number("123"), .string("false"), .bool(false), .null]))
    }

    @Test func unknownProviderAndPayloadRemainInspectable() throws {
        let provider = try JSONDecoder().decode(ConversationProvider.self, from: Data(#""future-provider""#.utf8))
        #expect(provider == .unknown("future-provider"))
        let raw = Data(#"{"future":{"empty":null,"enabled":true,"parts":["text",42]}}"#.utf8)
        let value = try JSONDecoder().decode(ConversationJSONValue.self, from: raw)
        #expect(try JSONDecoder().decode(ConversationJSONValue.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func futureCommandsFailClosedAndPreconditionsRoundTrip() throws {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ConversationCommand.self, from: Data(#"{"kind":"future-operation"}"#.utf8))
        }
        let command = ConversationCommandEnvelope(commandID: "command", sessionID: "session", expectedGeneration: "generation", expectedTurnID: "turn", command: .steer(text: "Keep the API unchanged"))
        #expect(try JSONDecoder().decode(ConversationCommandEnvelope.self, from: JSONEncoder().encode(command)) == command)
    }
}
