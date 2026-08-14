import Foundation
import Testing

@testable import CmuxMobileShell

@Suite("Presence sync transport")
struct PresenceSyncTransportTests {
    @Test("duplicate ping failures complete only once")
    func duplicatePingFailuresCompleteOnlyOnce() async {
        do {
            try await PresenceSyncTransport.awaitPingCallback(
                { completion in
                    completion(URLError(.cancelled))
                    completion(URLError(.cancelled))
                },
                onCancel: {}
            )
            Issue.record("the first ping failure should be propagated")
        } catch {
            #expect((error as? URLError)?.code == .cancelled)
        }
    }
}
