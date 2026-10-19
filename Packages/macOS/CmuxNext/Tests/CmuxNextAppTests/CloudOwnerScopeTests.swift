import CmuxNextCloud
import Foundation
import Testing

@Suite struct CloudOwnerScopeTests {
    private actor Credentials {
        var reads = 0
        func read() -> String { reads += 1; return "unused-test-session" }
    }
    @Test func aMissingTeamRefusesBeforeReadingTheAccountCredential() async {
        let credentials = Credentials()
        // An unsupported scheme prevents any network I/O even on the old, unfenced path.
        let client = CloudOwnerAPIClient(baseURL: URL(string: "scope-test://owner")!,
            accessToken: { await credentials.read() }, teamID: { nil })
        do {
            _ = try await client.acpmuxPersonHolds("vm_" + String(repeating: "1", count: 20), nonce: "scope-test")
            Issue.record("an unscoped request must be refused")
        } catch CloudAPIError.notSignedIn { }
        catch { Issue.record("expected the missing-team refusal") }
        #expect(await credentials.reads == 0)
    }
}
