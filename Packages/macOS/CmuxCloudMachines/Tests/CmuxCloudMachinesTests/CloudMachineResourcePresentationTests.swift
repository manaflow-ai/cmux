import Foundation
import Testing
@testable import CmuxCloudMachines

@Suite("Cloud machine resource readings")
struct CloudMachineResourcePresentationTests {
    @Test func awakeReadingsDescribeUsageRatherThanProvisionedCapacity() {
        let result = CloudMachineResourcePresentation(
            availability: .awake, cpuPercent: 9.4,
            memoryUsedMb: 2048, memoryTotalMb: 4096,
            diskUsedMb: 3072, diskTotalMb: 4096
        )
        #expect(result.cpu.percent == 9.4)
        #expect(result.memory.percent == 50)
        #expect(result.disk.percent == 75)
        #expect(result.cpu.value == (0.094).formatted(.percent.precision(.fractionLength(0))))
        #expect(result.memory.detail.contains("2/4"))
        #expect(result.disk.detail.contains("3/4"))
    }

    @Test func zeroIsARealReadingAndMissingSamplesKeepTheirLabels() {
        let result = CloudMachineResourcePresentation(
            availability: .awake, cpuPercent: 0, memoryTotalMb: 4096,
            diskUsedMb: 0, diskTotalMb: 4096
        )
        #expect(result.cpu.percent == 0)
        #expect(result.memory.percent == nil)
        #expect(result.disk.percent == 0)
        #expect(result.cpu.value != result.memory.value)
        #expect(!result.memory.label.isEmpty)
        #expect(!result.memory.detail.isEmpty)
    }

    @Test(arguments: [CloudMachineResourcePresentation.Availability.asleep, .unavailable])
    func inactiveSamplesNeverPresentOldValuesAsLive(availability: CloudMachineResourcePresentation.Availability) {
        let result = CloudMachineResourcePresentation(
            availability: availability, cpuPercent: 83,
            memoryUsedMb: 2048, memoryTotalMb: 4096,
            diskUsedMb: 3072, diskTotalMb: 4096
        )
        #expect(result.cpu.percent == nil)
        #expect(result.memory.percent == nil)
        #expect(result.disk.percent == nil)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -1, 101, .greatestFiniteMagnitude])
    func malformedCPUIsUnavailableWithoutTrapping(cpu: Double) {
        let result = CloudMachineResourcePresentation(availability: .awake, cpuPercent: cpu)
        #expect(result.cpu.percent == nil)
        #expect(!result.cpu.value.isEmpty)
    }

    @Test(arguments: [(0, 0), (2, -1), (-1, 1024)])
    func invalidCapacityIsUnavailable(counts: (Int, Int)) {
        let result = CloudMachineResourcePresentation(
            availability: .awake, memoryUsedMb: counts.0, memoryTotalMb: counts.1,
            diskUsedMb: counts.0, diskTotalMb: counts.1
        )
        #expect(result.memory.percent == nil)
        #expect(result.disk.percent == nil)
    }

    @Test func capacityCounterRacesStayBounded() {
        let result = CloudMachineResourcePresentation(
            availability: .awake, memoryUsedMb: 4097, memoryTotalMb: 4096,
            diskUsedMb: .max, diskTotalMb: 4096
        )
        #expect(result.memory.percent == 100)
        #expect(result.disk.percent == 100)
    }
}
