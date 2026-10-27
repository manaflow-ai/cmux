@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextFeatures
import CmuxNextIPC
import Testing

/// The production wiring of `terminalStreams` (p05-ipc-095): on, the local daemon's connection streams its
/// terminal views, echoes the grant and joins shared sizing as this Mac; off (the default), it asks for none.
/// And of `ipcFrames` (p05-ipc-096): on, the same connection asks for framed IPC with this build's schema.
struct TerminalStreamsWiringTests {
    private static func features(enabling names: Set<String>) -> FeatureList {
        FeatureList(registry: FeatureRegistry(), channel: .dev, overrides: FeatureOverrides(environmentEnabled: names))
    }

    private static func localConfiguration(_ features: FeatureList) -> DaemonConnection.Configuration {
        DaemonService.localConfiguration(terminalEnvironment: nil, resolvesShellIntegration: false, installKey: nil,
                                         echoesPlacementShift: false, terminalStreams: CmuxNextApp.terminalStreams(features),
                                         wireUpgrades: CmuxNextApp.wireUpgrades(features))
    }

    /// Red before `ipcFrames` was wired (the local connection never asked for `ipc-frames-v2`, so no view's keys
    /// could go as INPUT frames, p05-ipc-096): on with `terminalStreams`, the local connection asks for frames
    /// with this build's method table and schema identity, and for the stream grant.
    @Test func ipcFramesOnAsksForFramesWithThisBuildsSchemaAndStreams() throws {
        let configuration = Self.localConfiguration(Self.features(enabling: ["ipcFrames", "terminalStreams"]))
        let frames = try #require(configuration.wireUpgrades.frames)
        #expect(frames.identity == .built)
        #expect(frames.table.methods.map(\.id) == MethodTable.schema.methods.map(\.id))
        #expect(configuration.wireUpgrades.streams)
        #expect(configuration.streamsTerminals)
    }

    /// Frames alone ask for no stream grant; with `ipcFrames` off (the default) the connection asks for no
    /// framed IPC at all and keeps JSON lines, whatever `terminalStreams` says.
    @Test(arguments: [["ipcFrames"], ["terminalStreams"], []] as [Set<String>])
    func ipcFramesAsksOnlyWhatIsOn(enabled: Set<String>) {
        let upgrades = Self.localConfiguration(Self.features(enabling: enabled)).wireUpgrades
        let framed = upgrades.frames != nil
        #expect(framed == enabled.contains("ipcFrames"))
        #expect(!upgrades.streams)
        #expect(upgrades.asksAny == enabled.contains("ipcFrames"))
    }

    @Test func onTheLocalConnectionStreamsTerminalsAsThisMac() async throws {
        let configuration = Self.localConfiguration(Self.features(enabling: ["terminalStreams"]))
        #expect(configuration.streamsTerminals)
        #expect(configuration.handshakeCapabilities.contains(TerminalAttachment.streamsCapability))
        #expect(configuration.handshakeCapabilities.contains(DaemonCapability.sharedSizing.rawValue))
        let device = try #require(configuration.streamSizingDevice)
        #expect(await device().kind == "mac")
    }

    @Test func offTheLocalConnectionKeepsAConnectionPerView() {
        let configuration = Self.localConfiguration(Self.features(enabling: []))
        #expect(!configuration.streamsTerminals)
        let hasDevice = configuration.streamSizingDevice != nil
        #expect(!hasDevice)
        #expect(!configuration.handshakeCapabilities.contains(TerminalAttachment.streamsCapability))
    }
}
