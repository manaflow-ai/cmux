import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite
struct MobileShellTerminalLaneConfigurationTests {
    @Test
    func inputOnlyProviderAloneCreatesLaneCoordinator() {
        let runtime = RoutingTestRuntime(
            transportFactory: LaneConfigurationTestTransportFactory(),
            terminalInputLaneProvider: { _, _, _ in
                fatalError("the provider is only used after mounting a terminal")
            }
        )

        let store = MobileShellComposite(runtime: runtime)

        #expect(store.terminalLaneCoordinator != nil)
    }
}

private struct LaneConfigurationTestTransportFactory: CmxByteTransportFactory {
    func makeTransport(for _: CmxAttachRoute) throws -> any CmxByteTransport {
        fatalError("the transport is not used by this configuration test")
    }
}
