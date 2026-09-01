import Testing
@testable import CmuxControlSocket

@Suite("Socket stream error classification")
struct SocketStreamErrorKindTests {
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

    @Test func otherErrorLinesAreServerErrors() {
        #expect(SocketStreamErrorKind.classify(line: "ERROR: Unknown method") == .server)
        #expect(SocketStreamErrorKind.classify(line: "ERROR:") == .server)
    }

    @Test func normalProtocolLinesHaveNoErrorKind() {
        #expect(SocketStreamErrorKind.classify(line: "{\"type\":\"event\"}") == nil)
        #expect(SocketStreamErrorKind.classify(line: "OK") == nil)
    }
}
