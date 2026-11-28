@testable import CmuxCloud
import Testing

/// `cmux ai-accounts` shows the client's error text (#21754), so the text is localized.
/// Outside the app no catalog is loaded and each message falls back to its English
/// default; these pin that English, including where the interpolated values land.
@Suite struct AIAccountsClientErrorTextTests {
    @Test func errorTextKeepsItsEnglish() {
        let cases: [(AIAccountsClientError, String)] = [
            (.notSignedIn, "Not signed in. Run `cmux auth login`, then retry."),
            (.sessionRefreshFailed, "Signed in, but cmux could not refresh your session (network or server issue). Retry in a moment."),
            (.malformedResponse("non-HTTP response"), "The AI accounts service returned an unexpected response: non-HTTP response"),
            (.backendUnreachable(url: "https://example.test:443", detail: "The request timed out."),
             "Could not reach the cmux backend at https://example.test:443: The request timed out."),
            (.httpStatus(503, ""), "AI accounts are not configured on this cmux backend."),
            (.httpStatus(401, ""), "Not signed in or session expired. Run `cmux auth login`, then retry."),
            (.httpStatus(500, #"{"error":"subrouter down"}"#), "AI accounts request failed (HTTP 500): subrouter down"),
            (.httpStatus(502, "not json"), "AI accounts request failed (HTTP 502)."),
        ]
        for (error, english) in cases {
            #expect(error.description == english)
        }
    }
}
