@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextFeatures
import CmuxNextIPC
import Testing

/// Feature `ipcRequestFrames` (p05-ipc-180) is how a recording of the real app gets framed requests: on, the app's
/// local daemon connection asks for REQUEST frames with this build's schema, so a traced request carries its flow id
/// app -> daemon -> app; off (the default), the connection asks for no upgrade and speaks JSON lines.
@MainActor @Suite struct LocalDaemonRequestFramesTests {
    private static func features(enabling names: Set<String>) -> FeatureList {
        FeatureList(registry: FeatureRegistry(), channel: .dev, overrides: FeatureOverrides(environmentEnabled: names))
    }

    private static func localConfiguration(_ upgrades: DaemonWireUpgrades) -> DaemonConnection.Configuration {
        DaemonService.localConfiguration(terminalEnvironment: nil, resolvesShellIntegration: false, installKey: nil,
                                         echoesPlacementShift: false, wireUpgrades: upgrades)
    }

    @Test func theFeatureOffKeepsTheLocalConnectionOnLines() {
        let upgrades = CmuxNextApp.localDaemonWireUpgrades(Self.features(enabling: []))
        #expect(upgrades.frames == nil)
        #expect(!upgrades.streams)
        #expect(Self.localConfiguration(upgrades).wireUpgrades.frames == nil)
    }

    @Test func theFeatureOnAsksTheLocalConnectionForFramesWithThisBuildsSchema() {
        let upgrades = CmuxNextApp.localDaemonWireUpgrades(Self.features(enabling: ["ipcRequestFrames"]))
        #expect(upgrades.frames?.identity == WireSchemaIdentity.built)
        #expect(!upgrades.streams)
        let local = Self.localConfiguration(upgrades)
        #expect(local.wireUpgrades.frames?.identity == WireSchemaIdentity.built)
        #expect(local.reportsDiagnosticSites)
    }
}
