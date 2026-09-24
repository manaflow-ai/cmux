import Testing
@testable import CmuxControlSocket

@Suite("Socket stream error classification")
struct SocketStreamErrorKindTests {
    /// Recognizes both the stable English fixture and a caller-supplied localized response.
    @Test func accessDeniedLinesAreClassified() {
        #expect(
            SocketStreamErrorKind.classify(
                line: "ERROR: Access denied - only processes started inside cmux can connect"
            ) == .accessDenied
        )
        #expect(
            SocketStreamErrorKind.classify(
                line: "ERROR: Accès refusé",
                localizedAccessDeniedResponse: "ERROR: Accès refusé"
            ) == .accessDenied
        )
    }

    /// Keeps unrelated protocol errors in the generic server-error category.
    @Test func otherErrorLinesAreServerErrors() {
        #expect(SocketStreamErrorKind.classify(line: "ERROR: Unknown method") == .server)
        #expect(SocketStreamErrorKind.classify(line: "ERROR:") == .server)
    }

    /// Leaves JSON and non-error protocol lines available to the stream decoder.
    @Test func normalProtocolLinesHaveNoErrorKind() {
        #expect(SocketStreamErrorKind.classify(line: "{\"type\":\"event\"}") == nil)
        #expect(SocketStreamErrorKind.classify(line: "OK") == nil)
    }
}
