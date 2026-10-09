import CmuxMobileHost
import CmuxMobileWire
@testable import CmuxMobileConnectHost
import Testing

@Suite("host features")
struct HostFeaturesTests {
    @Test("extra caps join the defaults once; both spawn gates stay off unless set")
    func configuration() {
        let plain = MobileHostFeatures().configuration(hostID: "host_1", accountUserID: "user_1")
        #expect(plain.caps == MobileHostConfiguration.defaultCaps)
        #expect(!plain.allowsTaskDispatch && !plain.allowsTerminalSpawn)
        let git = MobileHostFeatures(caps: ["git.read", "read"]).configuration(hostID: "host_1", accountUserID: "user_1")
        #expect(git.caps == MobileHostConfiguration.defaultCaps + ["git.read"])
    }

    @Test("host status carries owner metadata and the complete capability set")
    func statusPayload() {
        let config = MobileHostFeatures(caps: ["git.read"], displayName: "Studio",
                                        appVersion: "1.2.3", appBuild: "42")
            .configuration(hostID: "host_1", accountUserID: "user_1")
        #expect(config.statusPayload["mac_device_id"]?.stringValue == "host_1")
        #expect(config.statusPayload["mac_display_name"]?.stringValue == "Studio")
        #expect(config.statusPayload["mac_app_version"]?.stringValue == "1.2.3")
        #expect(config.statusPayload["mac_app_build"]?.stringValue == "42")
        #expect(config.statusPayload["capabilities"]?.arrayValue?.count == config.caps.count)
    }
}

private extension JSONValue {
    var arrayValue: [Self]? {
        guard case .array(let values) = self else { return nil }
        return values
    }
}
