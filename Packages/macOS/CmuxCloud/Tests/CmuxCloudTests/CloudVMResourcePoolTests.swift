@testable import CmuxCloud
import Foundation
import Testing

@Suite
struct CloudVMResourcePoolTests {
    private static let proLimits: [String: Any] = [
        "planId": "pro",
        "poolVcpus": 20,
        "poolMemoryMb": 40960,
        "usedVcpus": 16,
        "usedMemoryMb": 32768,
    ]

    @Test
    func decodesThePoolFromListLimits() throws {
        let pool = try #require(CloudVMResourcePool(limits: Self.proLimits))
        #expect(pool == CloudVMResourcePool(poolVcpus: 20, poolMemoryMb: 40960, usedVcpus: 16, usedMemoryMb: 32768))
        #expect(pool.freeVcpus == 4)
        #expect(pool.freeMemoryMb == 8192)
        #expect(!pool.isExhausted)
    }

    @Test
    func plansWithoutAPoolAndOlderServersDecodeNoPool() {
        #expect(CloudVMResourcePool(limits: ["planId": "go", "poolVcpus": NSNull(), "poolMemoryMb": NSNull()]) == nil)
        #expect(CloudVMResourcePool(limits: ["planId": "pro", "maxActiveVms": 5]) == nil)
        // A pool without usage reads as nothing in use.
        #expect(CloudVMResourcePool(limits: ["poolVcpus": 80, "poolMemoryMb": 163840])?.usedMemoryMb == 0)
    }

    @Test
    func decodesPerMachineReservationForResizeGates() throws {
        let reservation = try #require(VMClient.decodeResourceReservation([
            "vcpus": 8,
            "memoryMb": 16 * 1024,
            "diskMb": 128 * 1024,
        ]))
        #expect(reservation == CloudVMResourceReservation(vcpus: 8, memoryMb: 16 * 1024, diskMb: 128 * 1024))
        #expect(VMClient.decodeResourceReservation(["vcpus": NSNull(), "memoryMb": 8192]) == nil)
    }

    @Test
    func memoryOverflowIsReportedBeforeVcpus() throws {
        let pool = try #require(CloudVMResourcePool(limits: Self.proLimits))
        #expect(pool.shortfall(vcpus: 4, memoryMb: 8192) == nil)
        #expect(pool.shortfall(vcpus: 8, memoryMb: 16384) == .memory(requestedMb: 16384, freeMb: 8192, poolMb: 40960))
        let vcpuBound = CloudVMResourcePool(poolVcpus: 20, poolMemoryMb: 40960, usedVcpus: 18, usedMemoryMb: 8192)
        #expect(vcpuBound.shortfall(vcpus: 4, memoryMb: 8192) == .vcpus(requested: 4, free: 2, pool: 20))
        #expect(vcpuBound.isExhausted == false)
        #expect(CloudVMResourcePool(poolVcpus: 20, poolMemoryMb: 40960, usedVcpus: 20, usedMemoryMb: 40960).isExhausted)
    }

    @Test
    func shortfallTextNamesTheNumbersAndOffersMaxOnlyBelowMax() {
        let shortfall = CloudVMResourcePool.Shortfall.memory(requestedMb: 16384, freeMb: 8192, poolMb: 40960)
        let pro = CloudVMResourcePool.shortfallText(shortfall, offersUpgrade: true)
        #expect(pro.contains("16 GB"))
        #expect(pro.contains("8 GB"))
        #expect(pro.contains("40 GB"))
        #expect(pro.contains("Max"))
        let max = CloudVMResourcePool.shortfallText(shortfall, offersUpgrade: false)
        #expect(!max.contains("Max"))
    }

    @Test
    func usageCarriesThePoolIntoTheHeaderTooltip() throws {
        let pool = try #require(CloudVMResourcePool(limits: Self.proLimits))
        #expect(pool.usageText.contains("16"))
        #expect(pool.usageText.contains("20"))
        #expect(pool.usageText.contains("32"))
        #expect(pool.usageText.contains("40"))
        let limits = VMPlanLimits(maxActiveVms: 5, planId: "pro", freeAccessWindowDays: 0, resourcePool: pool)
        let plan = try #require(MachineSnapshotBuilder.planSnapshot(activeCount: 2, limits: limits))
        #expect(plan.resourcePool == pool)
        #expect(plan.usage.help.hasSuffix(pool.usageText))
        let full = CloudMachinesUsage(
            activeCount: 2,
            maxActiveVms: 5,
            isPaidPlan: true,
            resourcePool: CloudVMResourcePool(poolVcpus: 20, poolMemoryMb: 40960, usedVcpus: 20, usedMemoryMb: 40960)
        )
        #expect(!full.isAtLimit)
        #expect(CloudTreeGroupCount(usage: full).isWarning)
    }

    @Test
    func poolErrorActionLinksMaxCheckoutOnlyWhenTheServerOffersMax() {
        let upgrade = defaultCloudVMAction(
            status: 402,
            errorCode: "vm_resource_pool_exceeded",
            response: ["upgradePlanId": "max"]
        )
        #expect(upgrade.contains("cmux_source=\(ProUpgradeSource.vmResourcePoolExceededError.rawValue)"))
        #expect(upgrade.contains("plan=max"))
        let nested = defaultCloudVMAction(
            status: 402,
            errorCode: "vm_resource_pool_exceeded",
            response: ["details": ["upgradePlanId": "max"]]
        )
        #expect(nested.contains("plan=max"))
        let onMax = defaultCloudVMAction(
            status: 402,
            errorCode: "vm_resource_pool_exceeded",
            response: ["upgradePlanId": NSNull()]
        )
        #expect(!onMax.contains("checkout"))
    }

    @Test
    func formattedPoolErrorKeepsTheServerMessageAndAddsTheCheckoutLink() {
        let body = """
        {"error":"vm_resource_pool_exceeded","message":"Your VMs already use 32 of 40 GB RAM. This VM needs 16 GB.",
         "action":"Pause or delete a VM, or upgrade to Max.","upgradePlanId":"max",
         "details":{"resource":"memoryMb","poolMemoryMb":40960,"usedMemoryMb":32768,"requestedMemoryMb":16384}}
        """
        let text = formattedCloudVMHTTPError(status: 402, body: body)
        #expect(text.contains("Your VMs already use 32 of 40 GB RAM."))
        #expect(text.contains("cmux_source=\(ProUpgradeSource.vmResourcePoolExceededError.rawValue)"))
        #expect(text.contains("poolMemoryMb: 40960"))
    }
}
