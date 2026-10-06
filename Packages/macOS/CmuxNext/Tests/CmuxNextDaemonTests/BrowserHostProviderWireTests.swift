import Foundation
import Testing
@testable import CmuxNextDaemon

/// `browser-host-provider` (`browser-host-provider-v1`): the app asks with no fields and reads
/// the provider socket, the secret and the host's pid.
@Suite struct BrowserHostProviderWireTests {
    @Test func theRequestCarriesOnlyTheCommand() throws {
        let data = try WireCoding.encodeRequest(BrowserHostProviderRequest(), id: 7)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        #expect(object["cmd"] == .string("browser-host-provider"))
        #expect(Set(object.keys) == ["cmd", "id"])
    }

    @Test func theReplyNamesTheSocketTheSecretAndTheHostPID() throws {
        let json = #"{"socket":"/tmp/bh-1/browser-host-provider.sock","secret":"ab12","host_pid":4242,"listener_pid":17}"#
        let reply = try JSONDecoder().decode(BrowserHostProviderRequest.Response.self, from: Data(json.utf8))
        #expect(reply == .init(socket: "/tmp/bh-1/browser-host-provider.sock", secret: "ab12", hostPID: 4242, listenerPID: 17))
        let older = #"{"socket":"/s","secret":"ab12","host_pid":4242}"#
        #expect(try JSONDecoder().decode(BrowserHostProviderRequest.Response.self, from: Data(older.utf8)).listenerPID == nil)
    }
}
