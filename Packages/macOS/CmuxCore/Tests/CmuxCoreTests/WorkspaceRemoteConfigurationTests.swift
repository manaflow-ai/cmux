import Foundation
import Testing
@testable import CmuxCore

@Suite("WorkspaceRemoteConfiguration SSH option normalization")
struct WorkspaceRemoteConfigurationNormalizationTests {
    @Test("durable options drop transient control-socket keys, any separator or case")
    func durableOptionsDropControlSocketKeys() {
        let options = [
            "ControlMaster=auto",
            "controlpath /tmp/sock-%C",
            "ControlPersist=600",
            "ServerAliveInterval=20",
            "  ForwardAgent yes  ",
            "",
            "   ",
        ]
        #expect(WorkspaceRemoteConfiguration.durableSSHOptions(options) == [
            "ServerAliveInterval=20",
            "ForwardAgent yes",
        ])
    }

    @Test("trimmed options keep control-socket keys but trim whitespace and drop empties")
    func trimmedOptionsKeepControlKeys() {
        let options = [" ControlMaster=auto ", "", "ServerAliveInterval=20"]
        #expect(WorkspaceRemoteConfiguration.trimmedSSHOptions(options) == [
            "ControlMaster=auto",
            "ServerAliveInterval=20",
        ])
    }

    @Test("forked workspace options equal the durable subset")
    func forkedOptionsMatchDurable() {
        let options = ["ControlPath=/tmp/x", "ForwardAgent=yes"]
        #expect(
            WorkspaceRemoteConfiguration.forkedWorkspaceSSHOptions(options)
                == WorkspaceRemoteConfiguration.durableSSHOptions(options)
        )
        #expect(
            WorkspaceRemoteConfiguration.forkedAgentSSHOptions(options)
                == WorkspaceRemoteConfiguration.durableSSHOptions(options)
        )
    }

    @Test("normalizedOptionalValue trims and rejects whitespace-only input")
    func normalizedOptionalValueBehavior() {
        #expect(WorkspaceRemoteConfiguration.normalizedOptionalValue("  x  ") == "x")
        #expect(WorkspaceRemoteConfiguration.normalizedOptionalValue("   ") == nil)
        #expect(WorkspaceRemoteConfiguration.normalizedOptionalValue(nil) == nil)
    }

    @Test("persistent daemon slot validation enforces charset, length, and dot names")
    func persistentDaemonSlotValidation() {
        #expect(WorkspaceRemoteConfiguration.normalizedPersistentDaemonSlot("work-1.A_b") == "work-1.A_b")
        #expect(WorkspaceRemoteConfiguration.normalizedPersistentDaemonSlot("  slot  ") == "slot")
        #expect(WorkspaceRemoteConfiguration.normalizedPersistentDaemonSlot(".") == nil)
        #expect(WorkspaceRemoteConfiguration.normalizedPersistentDaemonSlot("..") == nil)
        #expect(WorkspaceRemoteConfiguration.normalizedPersistentDaemonSlot("bad/slash") == nil)
        #expect(WorkspaceRemoteConfiguration.normalizedPersistentDaemonSlot("bad slot") == nil)
        #expect(WorkspaceRemoteConfiguration.normalizedPersistentDaemonSlot(String(repeating: "a", count: 129)) == nil)
        #expect(
            WorkspaceRemoteConfiguration.normalizedPersistentDaemonSlot(String(repeating: "a", count: 128))
                == String(repeating: "a", count: 128)
        )
        #expect(WorkspaceRemoteConfiguration.normalizedPersistentDaemonSlot(nil) == nil)
    }

    @Test("identity path trims and expands a leading tilde")
    func identityPathNormalization() {
        #expect(WorkspaceRemoteConfiguration.normalizedIdentityPath("  /id_ed25519  ") == "/id_ed25519")
        let expanded = WorkspaceRemoteConfiguration.normalizedIdentityPath("~/key")
        #expect(expanded == ("~/key" as NSString).expandingTildeInPath)
        #expect(WorkspaceRemoteConfiguration.normalizedIdentityPath("   ") == nil)
    }

    @Test("hasSSHOptionKey matches case-insensitively across separators")
    func hasOptionKeyBehavior() {
        let options = ["ControlMaster auto", "ServerAliveInterval=20"]
        #expect(WorkspaceRemoteConfiguration.hasSSHOptionKey(options, key: "controlmaster"))
        #expect(WorkspaceRemoteConfiguration.hasSSHOptionKey(options, key: "SERVERALIVEINTERVAL"))
        #expect(!WorkspaceRemoteConfiguration.hasSSHOptionKey(options, key: "ControlPath"))
    }
}

@Suite("WorkspaceRemoteConfiguration value behavior")
struct WorkspaceRemoteConfigurationValueTests {
    private func makeConfiguration(
        transport: WorkspaceRemoteTransport = .ssh,
        destination: String = "user@host",
        port: Int? = nil,
        identityFile: String? = nil,
        sshOptions: [String] = [],
        relayPort: Int? = nil,
        preserveAfterTerminalExit: Bool = false,
        persistentDaemonSlot: String? = nil,
        skipDaemonBootstrap: Bool = false
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            transport: transport,
            destination: destination,
            port: port,
            identityFile: identityFile,
            sshOptions: sshOptions,
            localProxyPort: nil,
            relayPort: relayPort,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: persistentDaemonSlot,
            skipDaemonBootstrap: skipDaemonBootstrap
        )
    }

    @Test("persistent daemon slot is gated on preserveAfterTerminalExit")
    func slotGatedOnPreserve() {
        #expect(makeConfiguration(persistentDaemonSlot: "slot").persistentDaemonSlot == nil)
        #expect(
            makeConfiguration(preserveAfterTerminalExit: true, persistentDaemonSlot: "slot")
                .persistentDaemonSlot == "slot"
        )
        #expect(
            makeConfiguration(preserveAfterTerminalExit: true, persistentDaemonSlot: "bad slot")
                .persistentDaemonSlot == nil
        )
    }

    @Test("displayTarget appends the port only when present")
    func displayTarget() {
        #expect(makeConfiguration().displayTarget == "user@host")
        #expect(makeConfiguration(port: 2222).displayTarget == "user@host:2222")
    }

    @Test("proxy broker transport key separates bootstrap modes and ignores transient options")
    func proxyBrokerTransportKey() {
        let base = makeConfiguration(sshOptions: ["ForwardAgent=yes", "ControlMaster=auto"])
        let sameIdentity = makeConfiguration(sshOptions: ["ForwardAgent=yes", "ControlPath=/tmp/x"])
        #expect(base.proxyBrokerTransportKey == sameIdentity.proxyBrokerTransportKey)

        let bakedVM = makeConfiguration(skipDaemonBootstrap: true)
        #expect(base.proxyBrokerTransportKey != bakedVM.proxyBrokerTransportKey)
        #expect(bakedVM.proxyBrokerTransportKey.contains("vm-baked"))

        let otherHost = makeConfiguration(destination: "user@other")
        #expect(base.proxyBrokerTransportKey != otherHost.proxyBrokerTransportKey)
    }

    @Test("hasSamePersistentPTYIdentity requires preserve on both sides and a matching slot")
    func persistentPTYIdentity() {
        let a = makeConfiguration(relayPort: 7000, preserveAfterTerminalExit: true, persistentDaemonSlot: "slot")
        let b = makeConfiguration(relayPort: 7000, preserveAfterTerminalExit: true, persistentDaemonSlot: "slot")
        #expect(a.hasSamePersistentPTYIdentity(as: b))

        let differentSlot = makeConfiguration(relayPort: 7000, preserveAfterTerminalExit: true, persistentDaemonSlot: "other")
        #expect(!a.hasSamePersistentPTYIdentity(as: differentSlot))

        let notPreserved = makeConfiguration(relayPort: 7000)
        #expect(!a.hasSamePersistentPTYIdentity(as: notPreserved))
        #expect(!notPreserved.hasSamePersistentPTYIdentity(as: a))

        let differentRelay = makeConfiguration(relayPort: 7001, preserveAfterTerminalExit: true, persistentDaemonSlot: "slot")
        #expect(!a.hasSamePersistentPTYIdentity(as: differentRelay))
    }

    @Test("sessionSnapshot persists only SSH transports with a non-empty destination")
    func sessionSnapshotGating() {
        #expect(makeConfiguration(transport: .local).sessionSnapshot() == nil)
        #expect(makeConfiguration(transport: .websocket).sessionSnapshot() == nil)
        #expect(makeConfiguration(destination: "   ").sessionSnapshot() == nil)

        let snapshot = makeConfiguration(
            destination: " user@host ",
            sshOptions: ["ControlMaster=auto", "ForwardAgent=yes"]
        ).sessionSnapshot()
        #expect(snapshot?.destination == "user@host")
        #expect(snapshot?.sshOptions == ["ForwardAgent=yes"])
        #expect(snapshot?.preserveAfterTerminalExit == nil)
        #expect(snapshot?.relayPort == nil)
    }

    @Test("sessionSnapshot keeps relay port and slot only for preserved sessions")
    func sessionSnapshotPreservedFields() {
        let snapshot = makeConfiguration(
            relayPort: 7000,
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "slot"
        ).sessionSnapshot()
        #expect(snapshot?.preserveAfterTerminalExit == true)
        #expect(snapshot?.relayPort == 7000)
        #expect(snapshot?.persistentDaemonSlot == "slot")
    }

    @Test("sshTerminalStartupEnvironment carries SSH_AUTH_SOCK only when an agent socket exists")
    func startupEnvironment() {
        #expect(makeConfiguration().sshTerminalStartupEnvironment == nil)
        #expect(makeConfiguration().sshProcessEnvironment == nil)
    }
}
