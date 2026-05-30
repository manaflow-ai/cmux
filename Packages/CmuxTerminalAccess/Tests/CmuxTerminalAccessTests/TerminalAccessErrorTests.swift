import Testing
@testable import CmuxTerminalAccess

@Suite struct TerminalAccessErrorTests {
    @Test func httpStatusesMatchDesignTable() {
        #expect(TerminalAccessError.unknownSurface.httpStatus == 404)
        #expect(TerminalAccessError.unauthorized.httpStatus == 401)
        #expect(TerminalAccessError.forbidden(reason: "x").httpStatus == 403)
        #expect(TerminalAccessError.badRequest(reason: "x").httpStatus == 400)
        #expect(TerminalAccessError.payloadTooLarge.httpStatus == 413)
        #expect(TerminalAccessError.rateLimited.httpStatus == 429)
        #expect(TerminalAccessError.featureDisabled.httpStatus == 404) // D11
        #expect(TerminalAccessError.unsupported(reason: "x").httpStatus == 415) // D18
        #expect(TerminalAccessError.ghosttyError("x").httpStatus == 500)
    }

    @Test func wireCodesAreStable() {
        #expect(TerminalAccessError.unknownSurface.wireCode == "unknown_surface")
        #expect(TerminalAccessError.unauthorized.wireCode == "unauthorized")
        #expect(TerminalAccessError.forbidden(reason: "x").wireCode == "forbidden")
        #expect(TerminalAccessError.badRequest(reason: "x").wireCode == "bad_request")
        #expect(TerminalAccessError.payloadTooLarge.wireCode == "payload_too_large")
        #expect(TerminalAccessError.rateLimited.wireCode == "rate_limited")
        #expect(TerminalAccessError.unsupported(reason: "x").wireCode == "unsupported_media_type")
        #expect(TerminalAccessError.featureDisabled.wireCode == "not_found")
        #expect(TerminalAccessError.ghosttyError("x").wireCode == "internal_error")
    }

    @Test func messagesPassThroughAssociatedValues() {
        #expect(TerminalAccessError.forbidden(reason: "no token role").message == "no token role")
        #expect(TerminalAccessError.badRequest(reason: "bad coords").message == "bad coords")
        #expect(TerminalAccessError.unsupported(reason: "want text/plain").message == "want text/plain")
        #expect(TerminalAccessError.ghosttyError("pty broken").message == "pty broken")
        #expect(TerminalAccessError.unknownSurface.message == "Unknown surface")
    }
}
