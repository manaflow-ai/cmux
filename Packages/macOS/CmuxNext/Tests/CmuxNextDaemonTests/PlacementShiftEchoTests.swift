@testable import CmuxNextDaemon
import Testing

/// `placement-shift-v1` is echoed by the connections whose configuration says this build orders
/// sidebar rows from the document, and only with `sidebar-doc-v1`. It used to come from a
/// process-wide static the App set during `AppServices.init`, after `main` had already begun the
/// prestart connection, so the first handshake could miss it.
@Suite struct PlacementShiftEchoTests {
    @Test func aConfigurationThatOrdersFromTheDocumentEchoesItWithTheSidebarDocument() {
        var configuration = DaemonConnectionConfiguration(terminalEnvironment: nil)
        configuration.advertisedCapabilities = [DaemonCapability.sidebarDoc.rawValue]
        #expect(!configuration.handshakeCapabilities.contains(DaemonCapability.placementShift.rawValue))

        configuration.echoesPlacementShift = true
        #expect(configuration.handshakeCapabilities.contains(DaemonCapability.placementShift.rawValue))

        // Never alone: without the sidebar document there is nothing to order from.
        configuration.advertisedCapabilities = []
        #expect(!configuration.handshakeCapabilities.contains(DaemonCapability.placementShift.rawValue))
    }

    @Test func twoConfigurationsInOneProcessEchoIndependently() {
        var sidebar = DaemonConnectionConfiguration(advertisedCapabilities: [DaemonCapability.sidebarDoc.rawValue], terminalEnvironment: nil)
        sidebar.echoesPlacementShift = true
        let other = DaemonConnectionConfiguration(advertisedCapabilities: [DaemonCapability.sidebarDoc.rawValue], terminalEnvironment: nil)
        #expect(sidebar.handshakeCapabilities.contains(DaemonCapability.placementShift.rawValue))
        #expect(!other.handshakeCapabilities.contains(DaemonCapability.placementShift.rawValue))
    }
}
