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
        #expect(result.inlineSummary.contains("CPU"))
        #expect(result.inlineSummary.contains("RAM"))
        #expect(result.inlineSummary.contains("Disk"))
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

    @Test func loadingAndStaleSamplesKeepTheirStateVisible() {
        let loading = CloudMachineResourcePresentation(availability: .loading)
        #expect(loading.availability == .loading)
        #expect(loading.cpu.value == "…")
        #expect(loading.cpu.detail.contains("Loading"))

        let stale = CloudMachineResourcePresentation(
            availability: .stale, cpuPercent: 83,
            memoryUsedMb: 2048, memoryTotalMb: 4096,
            diskUsedMb: 3072, diskTotalMb: 4096
        )
        #expect(stale.availability == .stale)
        #expect(stale.cpu.percent == nil)
        #expect(stale.cpu.value == "—")
        #expect(stale.disk.detail.contains("Stale"))
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

    @Test(arguments: [CloudMachineResourcePresentation.Availability.loading, .unavailable, .asleep, .stale])
    func knownCapacitySurvivesMissingTelemetry(availability: CloudMachineResourcePresentation.Availability) {
        let resources = CloudMachineResourcePresentation(
            availability: availability, cpuPercent: 80, cpus: 4,
            memoryUsedMb: 2048, memoryTotalMb: 8192,
            diskUsedMb: 4096, diskTotalMb: 32768
        )
        #expect(resources.cpu.percent == nil)
        #expect(resources.memory.percent == nil)
        #expect(resources.disk.percent == nil)
        #expect(resources.cpu.inlineDetail.contains("4 vCPU"))
        #expect(resources.memory.inlineDetail.contains("8 GB total"))
        #expect(resources.disk.inlineDetail.contains("32 GB total"))
        #expect(!resources.memory.inlineDetail.contains("2/8"))
        #expect(!resources.disk.inlineDetail.contains("4/32"))
        #expect(resources.availability == availability)
    }

    @Test func partialSamplesRetainCapacityWithoutInventingZero() {
        let resources = CloudMachineResourcePresentation(
            availability: .awake, cpuPercent: 0, cpus: 4,
            memoryTotalMb: 8192, diskUsedMb: 0, diskTotalMb: 32768
        )
        #expect(resources.cpu.percent == 0)
        #expect(resources.disk.percent == 0)
        #expect(resources.memory.percent == nil)
        #expect(resources.memory.inlineDetail == "8 GB total · Unavailable")
    }

    @Test func invalidCapacityRemainsUnavailable() {
        let resources = CloudMachineResourcePresentation(
            availability: .unavailable, cpus: 0, memoryTotalMb: -1, diskTotalMb: 0
        )
        #expect(resources.cpu.inlineDetail == "Unavailable")
        #expect(resources.memory.inlineDetail == "Unavailable")
        #expect(resources.disk.inlineDetail == "Unavailable")
    }

}
