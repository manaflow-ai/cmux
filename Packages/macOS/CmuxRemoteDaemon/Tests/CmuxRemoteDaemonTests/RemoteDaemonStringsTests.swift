import Testing
@testable import CmuxRemoteDaemon

@Suite("RemoteDaemonCapability wire strings")
struct RemoteDaemonCapabilityTests {
    @Test("raw values are the exact daemon hello capability strings")
    func rawValuesArePinned() {
        #expect(RemoteDaemonCapability.proxyStreamPush.rawValue == "proxy.stream.push")
        #expect(RemoteDaemonCapability.ptySession.rawValue == "pty.session")
        #expect(RemoteDaemonCapability.ptySessionToken.rawValue == "pty.session.token")
        #expect(RemoteDaemonCapability.ptyPersistentDaemon.rawValue == "pty.session.persistent_daemon")
        #expect(RemoteDaemonCapability.ptyWriteNotification.rawValue == "pty.write.notification")
    }

    @Test("the persistent PTY family is the four PTY capabilities")
    func persistentPTYFamily() {
        #expect(RemoteDaemonCapability.persistentPTYFamily == [
            "pty.session",
            "pty.session.token",
            "pty.session.persistent_daemon",
            "pty.write.notification",
        ])
    }
}

@Suite("RemoteDaemonStrings missing-capability messages")
struct RemoteDaemonStringsTests {
    private let strings = RemoteDaemonStrings(
        missingPersistentPTYCapability: "persistent-pty-message",
        missingRequiredFunctionality: "generic-message"
    )

    @Test("any missing persistent-PTY capability selects the persistent PTY message")
    func persistentPTYCapabilitySelected() {
        for capability in [
            "pty.session",
            "pty.session.token",
            "pty.session.persistent_daemon",
            "pty.write.notification",
        ] {
            #expect(
                strings.missingRequiredCapabilitiesMessage([capability])
                    == "persistent-pty-message"
            )
        }
        #expect(
            strings.missingRequiredCapabilitiesMessage(["proxy.stream.push", "pty.session"])
                == "persistent-pty-message"
        )
    }

    @Test("other missing capabilities fall back to the generic message")
    func genericMessageFallback() {
        #expect(strings.missingRequiredCapabilitiesMessage(["proxy.stream.push"]) == "generic-message")
        #expect(strings.missingRequiredCapabilitiesMessage([]) == "generic-message")
        #expect(strings.missingRequiredCapabilitiesMessage(["unknown.capability"]) == "generic-message")
    }
}
