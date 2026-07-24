import CmuxWorkspaceShare
import Testing

@Suite
struct WorkspaceShareGrantValidatorTests {
    @Test
    func `Share codes match worker grammar`() {
        #expect(WorkspaceShareGrantValidator.isValidCode("Abc12345"))
        #expect(
            WorkspaceShareGrantValidator.isValidCode(
                String(repeating: "Z", count: 64)
            )
        )
        #expect(!WorkspaceShareGrantValidator.isValidCode("short"))
        #expect(
            !WorkspaceShareGrantValidator.isValidCode(
                String(repeating: "Z", count: 65)
            )
        )
        #expect(!WorkspaceShareGrantValidator.isValidCode("code-with-dash"))
        #expect(!WorkspaceShareGrantValidator.isValidCode("コード12345678"))
    }

    @Test
    func `Tokens are bounded and reject controls`() {
        #expect(WorkspaceShareGrantValidator.isValidToken("a.b.c"))
        #expect(
            WorkspaceShareGrantValidator.isValidToken(
                String(
                    repeating: "a",
                    count: WorkspaceShareGrantValidator.maximumTokenBytes
                )
            )
        )
        #expect(!WorkspaceShareGrantValidator.isValidToken(""))
        #expect(
            !WorkspaceShareGrantValidator.isValidToken(
                String(
                    repeating: "a",
                    count: WorkspaceShareGrantValidator.maximumTokenBytes + 1
                )
            )
        )
        #expect(!WorkspaceShareGrantValidator.isValidToken("a\u{0085}b"))
    }

    @Test
    func `URL schemes are constrained while loopback dogfood remains valid`() {
        #expect(
            WorkspaceShareGrantValidator.webSocketURL(
                from: "wss://share.cmux.dev/v1/share/sessions/code12345/ws"
            ) != nil
        )
        #expect(
            WorkspaceShareGrantValidator.webSocketURL(
                from: "ws://127.0.0.1:8787/v1/share/sessions/code12345/ws"
            ) != nil
        )
        #expect(
            WorkspaceShareGrantValidator.sharePageURL(
                from: "http://localhost:3000/share/code12345"
            ) != nil
        )
        #expect(
            WorkspaceShareGrantValidator.sharePageURL(
                from: "https://cmux.com/share/code12345"
            ) != nil
        )
        #expect(
            WorkspaceShareGrantValidator.webSocketURL(
                from: "ws://127.42.0.9:8787/ws"
            ) != nil
        )
        #expect(
            WorkspaceShareGrantValidator.webSocketURL(
                from: "ws://[::1]:8787/ws"
            ) != nil
        )
        #expect(
            WorkspaceShareGrantValidator.webSocketURL(
                from: "https://share.cmux.dev/ws"
            ) == nil
        )
        #expect(
            WorkspaceShareGrantValidator.sharePageURL(
                from: "file:///tmp/share"
            ) == nil
        )
        #expect(
            WorkspaceShareGrantValidator.webSocketURL(
                from: "ws://evil.example/ws"
            ) == nil
        )
        #expect(
            WorkspaceShareGrantValidator.sharePageURL(
                from: "http://evil.example/share/code12345"
            ) == nil
        )
        #expect(
            WorkspaceShareGrantValidator.webSocketURL(
                from: "wss://user:password@share.cmux.dev/ws"
            ) == nil
        )
    }
}
