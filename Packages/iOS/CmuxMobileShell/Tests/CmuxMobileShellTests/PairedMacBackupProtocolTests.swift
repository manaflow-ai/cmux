import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

@Suite(.serialized) struct PairedMacBackupProtocolTests {
    private let strictScope = "cmux-dev:v2:ZmVhdHVyZQ"

    @Test func strictScopesSelectV2WhileReleaseAndLegacyStayOnV1() {
        #expect(PairedMacBackupClient.endpointURL(
            serviceBaseURL: "https://presence.example/base/",
            clientScope: strictScope
        )?.absoluteString == "https://presence.example/base/v2/sync/paired-macs")
        #expect(PairedMacBackupClient.endpointURL(
            serviceBaseURL: "https://presence.example",
            clientScope: nil
        )?.absoluteString == "https://presence.example/v1/sync/paired-macs")
        #expect(PairedMacBackupClient.endpointURL(
            serviceBaseURL: "https://presence.example",
            clientScope: "ios:legacy"
        )?.absoluteString == "https://presence.example/v1/sync/paired-macs")
    }

    @Test func unavailableV2WorkerFailsClosedWithoutV1Fallback() async {
        await UnavailableV2PairedMacURLProtocol.recorder.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnavailableV2PairedMacURLProtocol.self]
        let client = PairedMacBackupClient(
            serviceBaseURL: "https://old-worker.example",
            tokenSource: PresenceTokenSource(accessToken: { "access" }),
            clientScopeProvider: { self.strictScope },
            session: URLSession(configuration: configuration)
        )

        #expect(await client.fetchSnapshot() == nil)

        var request: URLRequest?
        for _ in 0..<100 where request == nil {
            request = await UnavailableV2PairedMacURLProtocol.recorder.requests.first
            await Task.yield()
        }
        #expect(request?.url?.path == "/v2/sync/paired-macs")
        #expect(request?.value(forHTTPHeaderField: "X-Cmux-Client-Scope") == strictScope)
        #expect(await UnavailableV2PairedMacURLProtocol.recorder.requests.count == 1)
    }
}
