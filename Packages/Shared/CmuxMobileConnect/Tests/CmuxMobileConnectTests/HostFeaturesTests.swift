import CmuxMobileHost
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
}
