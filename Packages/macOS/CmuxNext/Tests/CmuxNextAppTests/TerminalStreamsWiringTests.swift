@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextFeatures
import Testing

/// The production wiring of `terminalStreams`: on, the local daemon's connection streams its
/// terminal views, echoes the grant and joins shared sizing as this Mac; off (`CMUX_DISABLE_FEATURES`, and Release
/// by default), it asks for none.
struct TerminalStreamsWiringTests {
    private static func features(enabling names: Set<String>, disabling disabled: Set<String> = []) -> FeatureList {
        FeatureList(registry: FeatureRegistry(), channel: .dev,
                    overrides: FeatureOverrides(environmentDisabled: disabled, environmentEnabled: names))
    }

    private static func localConfiguration(_ features: FeatureList) -> DaemonConnection.Configuration {
        DaemonService.localConfiguration(terminalEnvironment: nil, resolvesShellIntegration: false, installKey: nil,
                                         echoesPlacementShift: false, terminalStreams: CmuxNextApp.terminalStreams(features))
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
        let configuration = Self.localConfiguration(Self.features(enabling: [], disabling: ["terminalStreams"]))
        #expect(!configuration.streamsTerminals)
        let hasDevice = configuration.streamSizingDevice != nil
        #expect(!hasDevice)
        #expect(!configuration.handshakeCapabilities.contains(TerminalAttachment.streamsCapability))
    }
}
