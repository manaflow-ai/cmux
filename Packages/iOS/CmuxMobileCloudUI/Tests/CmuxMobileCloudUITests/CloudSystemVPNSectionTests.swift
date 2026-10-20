#if os(iOS)
import CmuxMobileCloud
import Testing
@testable import CmuxMobileCloudUI

@Suite struct CloudSystemVPNSectionTests {
    @Test func advertisedMemoryWithoutDiskMetadataRemainsSelectable() {
        let limits = CloudMachineLimits(
            // 8 GiB is a legacy ladder row, but the server owns the map now.
            // An omitted row remains selectable and uses the safe ceiling.
            memoryOptionsMb: [8_192],
            maxDiskMb: 131_072,
            diskByMemoryMb: ["4096": 16_384]
        )
        #expect(CloudCreateMachineSheet.diskMb(for: 8_192, limits: limits) == 131_072)
    }

    @Test func explicitlyInvalidDiskMetadataRemovesOnlyThatSize() {
        let limits = CloudMachineLimits(
            memoryOptionsMb: [8_192, 20_480],
            maxDiskMb: 131_072,
            diskByMemoryMb: ["8192": 0]
        )
        #expect(CloudCreateMachineSheet.diskMb(for: 8_192, limits: limits) == nil)
        #expect(CloudCreateMachineSheet.diskMb(for: 20_480, limits: limits) == 131_072)
    }

    @Test func vcpuMapWithoutDiskMetadataUsesServerMaximumFallback() {
        let limits = CloudMachineLimits(
            memoryOptionsMb: [8_192],
            maxDiskMb: 131_072,
            vcpusByMemoryMb: ["8192": 8]
        )
        #expect(CloudCreateMachineSheet.diskMb(for: 8_192, limits: limits) == 131_072)
    }

    @Test func toggleIsDisabledDuringEveryTransitionPhase() {
        let phases: [CloudSystemVPNPhase] = [.preparing, .connecting, .disconnecting]

        for phase in phases {
            let section = CloudSystemVPNSection(
                phase: phase,
                isAvailable: true,
                enable: {},
                disable: {},
                retry: {}
            )
            #expect(section.isToggleDisabled)
        }
    }

    @Test func toggleStaysEnabledWhenStableAndAvailable() {
        let section = CloudSystemVPNSection(
            phase: .connected,
            isAvailable: true,
            enable: {},
            disable: {},
            retry: {}
        )

        #expect(!section.isToggleDisabled)
    }
}
#endif
