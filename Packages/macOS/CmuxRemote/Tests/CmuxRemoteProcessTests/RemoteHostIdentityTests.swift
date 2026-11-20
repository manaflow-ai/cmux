import CmuxRemoteHost
import Testing

@Suite struct RemoteHostIdentityTests {
    @Test func pinnedHelperRenameKeepsDeviceNamespace() {
        #expect(RemoteHostIdentity.deviceKeychainBundleIdentifier == "com.cmuxterm.remote.dev")
        #expect(RemoteHostIdentity.scopedDeviceKeychainIdentifier(scope: "capture.s0123") ==
                "com.cmuxterm.remote.dev.capture.s0123")
    }
}
