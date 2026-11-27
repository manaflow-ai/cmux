import Foundation
import Testing
@testable import CmuxMobileShell

/// Decodes real wire frames from the presence service (captured from the
/// workers/presence local proof) into the typed updates the device tree will
/// consume, so a server-side wire change breaks here before it breaks the UI.
@Suite struct PresenceWireParsingTests {
    private func parse(_ json: String) throws -> PresenceUpdate {
        try PresenceUpdate.parse(Data(json.utf8))
    }

    @Test func parsesSnapshot() throws {
        let json = """
        {"type":"snapshot","teamId":"team-1","now":1781048750410,
         "heartbeatIntervalMs":15000,"offlineTimeoutMs":45000,
         "devices":[{"deviceId":"cd013a31-1dec-408a-80c8-dedd234c2eff",
           "platform":"mac","displayName":"proof-mac","online":true,
           "lastSeenAt":1781048750392,
           "instances":[{"deviceId":"cd013a31-1dec-408a-80c8-dedd234c2eff",
             "tag":"default","platform":"mac","displayName":"proof-mac",
             "capabilities":[],"online":true,"lastSeenAt":1781048750392,
             "onlineSince":1781048750392}]}]}
        """
        guard case .snapshot(let snapshot) = try parse(json) else {
            Issue.record("expected snapshot")
            return
        }
        #expect(snapshot.teamId == "team-1")
        #expect(snapshot.heartbeatIntervalMs == 15000)
        #expect(snapshot.offlineTimeoutMs == 45000)
        #expect(snapshot.devices.count == 1)
        let device = try #require(snapshot.devices.first)
        #expect(device.online)
        #expect(device.displayName == "proof-mac")
        #expect(device.instances.first?.tag == "default")
    }

    @Test func parsesOnline() throws {
        let json = """
        {"type":"online","instance":{"deviceId":"d","tag":"default","platform":"mac",
         "capabilities":["terminal"],"online":true,"lastSeenAt":1,"onlineSince":1}}
        """
        guard case .online(let instance) = try parse(json) else {
            Issue.record("expected online")
            return
        }
        #expect(instance.online)
        #expect(instance.capabilities == ["terminal"])
        #expect(instance.onlineSince == 1)
        #expect(instance.offlineAt == nil)
    }

    @Test func parsesOfflineWithReason() throws {
        for (raw, reason) in [("timeout", PresenceOfflineReason.timeout),
                              ("goodbye", PresenceOfflineReason.goodbye)] {
            let json = """
            {"type":"offline","reason":"\(raw)","instance":{"deviceId":"d","tag":"t",
             "platform":"mac","capabilities":[],"online":false,"lastSeenAt":1,"offlineAt":2}}
            """
            guard case .offline(let instance, let parsedReason) = try parse(json) else {
                Issue.record("expected offline for reason \(raw)")
                continue
            }
            #expect(parsedReason == reason)
            #expect(!instance.online)
            #expect(instance.offlineAt == 2)
        }
    }

    @Test func parsesSeen() throws {
        let json = """
        {"type":"seen","deviceId":"d","tag":"dev","lastSeenAt":42}
        """
        #expect(try parse(json) == .seen(deviceId: "d", tag: "dev", lastSeenAt: 42))
    }

    @Test func parsesRoutesPushWithLenientRouteDecoding() throws {
        // One well-formed host/port route plus one unknown future kind: the
        // known route decodes, the unknown one drops, the frame never fails.
        let json = """
        {"type":"routes","instance":{"deviceId":"d","tag":"presvc","platform":"mac",
         "capabilities":[],"online":true,"lastSeenAt":5,"onlineSince":1,
         "routes":[
           {"id":"r1","kind":"tailscale","endpoint":{"type":"host_port","host":"100.0.0.1","port":51000}},
           {"kind":"quantum-teleport","coordinates":[1,2,3]}]}}
        """
        guard case .routes(let instance) = try parse(json) else {
            Issue.record("expected routes")
            return
        }
        #expect(instance.online)
        let routes = try #require(instance.routes)
        #expect(routes.count == 1)
        #expect(routes.first?.endpoint == .hostPort(host: "100.0.0.1", port: 51000))
    }

    @Test func instanceWithoutRoutesParsesAsNilRoutes() throws {
        let json = """
        {"type":"online","instance":{"deviceId":"d","tag":"default","platform":"mac",
         "capabilities":[],"online":true,"lastSeenAt":1,"onlineSince":1}}
        """
        guard case .online(let instance) = try parse(json) else {
            Issue.record("expected online")
            return
        }
        #expect(instance.routes == nil)
    }

    @Test func unknownMessageTypeThrows() {
        #expect(throws: PresenceClientError.self) {
            _ = try parse(#"{"type":"mystery"}"#)
        }
    }

    @Test func subscribeURLSwitchesToWebSocketScheme() {
        #expect(
            PresenceClient.subscribeURL(serviceBaseURL: "https://presence.example")?.absoluteString
                == "wss://presence.example/v1/presence/subscribe"
        )
        #expect(
            PresenceClient.subscribeURL(serviceBaseURL: "http://127.0.0.1:8799/")?.absoluteString
                == "ws://127.0.0.1:8799/v1/presence/subscribe"
        )
        #expect(PresenceClient.subscribeURL(serviceBaseURL: "ftp://nope") == nil)
    }
}
