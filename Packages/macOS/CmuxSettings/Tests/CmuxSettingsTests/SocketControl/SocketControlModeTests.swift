import Testing

import CmuxSettings

@Suite struct SocketControlModeTests {
    @Test func everyModeKeepsSocketOwnerPrivate() {
        for mode in SocketControlMode.allCases {
            #expect(mode.socketFilePermissions == 0o600)
        }
    }

    @Test func onlyPasswordModeRequiresAuth() {
        #expect(SocketControlMode.password.requiresPasswordAuth)
        for mode in [SocketControlMode.off, .cmuxOnly, .automation, .allowAll] {
            #expect(!mode.requiresPasswordAuth)
        }
    }

    @Test func rawValueIsStable() {
        #expect(SocketControlMode.cmuxOnly.rawValue == "cmuxOnly")
    }
}
