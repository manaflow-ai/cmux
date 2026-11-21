@testable import CmuxCloud
import CmuxCloudResizeCore
import CmuxSurfaceCatalogModel
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

    @Test(arguments: ["standby", "paused", "stopped", "PAUSED"])
    func catalogInactiveRowsDoNotSkipWakeTimePoolAdmission(status: String) throws {
        let inactive = SurfaceMachineInfo(
            id: .cloud("inactive"),
            name: "inactive",
            status: status,
            hasDesktop: true,
            linkState: .connected
        )
        let running = SurfaceMachineInfo(
            id: .cloud("running"),
            name: "running",
            status: "running",
            hasDesktop: true,
            linkState: .connected
        )
        let catalog = SurfaceCatalogSnapshot(
            machines: [inactive, running],
            resources: [],
            projections: []
        )

        let snapshots = MachineSnapshotBuilder.includingCatalogMachines([], catalog: catalog)
        #expect(snapshots.map(\.usesResourcePool) == [false, true])

        let summary = VMSummary(
            id: "inactive-summary",
            provider: "freestyle",
            status: status,
            image: "snapshot",
            createdAt: 0
        )
        #expect(!MachineSnapshotBuilder.snapshot(from: summary).usesResourcePool)
    }

    @Test(arguments: ["running", "provisioning", "ready", "creating", "starting", "pending", "resuming"])
    func activeStatusesUsePoolForCatalogAndSummaryRows(status: String) throws {
        let info = SurfaceMachineInfo(
            id: .cloud("active"),
            name: "active",
            status: status,
            hasDesktop: true,
            linkState: .connected
        )
        let catalog = SurfaceCatalogSnapshot(
            machines: [info],
            resources: [],
            projections: []
        )

        let catalogSnapshot = try #require(
            MachineSnapshotBuilder.includingCatalogMachines([], catalog: catalog).first
        )
        #expect(catalogSnapshot.usesResourcePool)

        let summary = VMSummary(
            id: "active-summary",
            provider: "freestyle",
            status: status,
            image: "snapshot",
            createdAt: 0
        )
        #expect(MachineSnapshotBuilder.snapshot(from: summary).usesResourcePool)
    }

    @Test(arguments: ["running", "provisioning", "ready", "creating", "starting", "pending", "resuming", "READY", " resuming "])
    func activeStatusesConsumeTheSharedPool(status: String) throws {
        let catalog = SurfaceCatalogSnapshot(
            machines: [SurfaceMachineInfo(
                id: .cloud("catalog-machine"),
                name: "catalog-machine",
                status: status,
                hasDesktop: true,
                linkState: .connected
            )],
            resources: [],
            projections: []
        )
        let catalogSnapshot = MachineSnapshotBuilder.includingCatalogMachines([], catalog: catalog)
        #expect(catalogSnapshot.first?.usesResourcePool == true)

        let summary = VMSummary(id: "summary-machine", provider: "freestyle", status: status, image: "image", createdAt: 1)
        #expect(MachineSnapshotBuilder.snapshot(from: summary).usesResourcePool)
    }

    @Test
    func validatorUsesPlanSpecificFallbackCeilings() throws {
        let validator = CloudVMResizePlanValidator()
        let go = try validator.plan(from: ["planId": "go"])
        let pro = try validator.plan(from: ["planId": "pro"])
        let max = try validator.plan(from: ["planId": "max"])

        #expect(go.limits.maxDiskMb == 128 * 1024)
        #expect(go.limits.maxMemoryMb == 16 * 1024)
        #expect(go.limits.maxVcpus == 8)
        #expect(pro.limits.maxDiskMb == 128 * 1024)
        #expect(pro.limits.maxMemoryMb == 16 * 1024)
        #expect(pro.limits.maxVcpus == 8)
        #expect(max.limits.maxDiskMb == 256 * 1024)
        #expect(max.limits.maxMemoryMb == 64 * 1024)
        #expect(max.limits.maxVcpus == 32)
    }

    @Test
    func validatorUsesFreeFallbackForMissingOrUnknownPlan() throws {
        let validator = CloudVMResizePlanValidator()
        for rawLimits in [
            [:] as [String: Any],
            ["planId": "unrecognized"] as [String: Any],
        ] {
            let plan = try validator.plan(from: rawLimits)
            #expect(plan.limits.maxMemoryMb == 8 * 1_024)
            #expect(plan.limits.maxVcpus == 4)
            #expect(plan.limits.maxDiskMb == 128 * 1_024)
        }
    }

    @Test
    func validatorCapsLegacyLadderAtTheCurrentPlanCeiling() throws {
        let limits: [String: Any] = [
            "planId": "pro",
            "memoryOptionsMb": [4096, 8192, 16384, 24576, 32768, 65536],
            "maxVcpus": 32,
        ]
        let plan = try CloudVMResizePlanValidator().plan(from: limits)
        #expect(plan.limits.maxMemoryMb == 16 * 1024)
        #expect(plan.limits.maxVcpus == 8)
    }

    @Test
    func validatorTakesACurrentServersMemoryCeilingAboveTheTier() throws {
        // A team's custom deal raises maxMemoryMb past the tier (#41335).
        // lockedMemoryOptionsMb marks a control plane that sends it.
        let team = try CloudVMResizePlanValidator().plan(from: [
            "planId": "team",
            "maxMemoryMb": 24 * 1_024,
            "maxVcpus": 12,
            "memoryOptionsMb": [4096, 8192, 16384, 24576],
            "lockedMemoryOptionsMb": [32768, 65536],
        ])
        #expect(team.limits.maxMemoryMb == 24 * 1_024)
        #expect(team.limits.maxVcpus == 12)

        let oversized = try CloudVMResizePlanValidator().plan(from: [
            "planId": "pro",
            "maxMemoryMb": 128 * 1_024,
            "lockedMemoryOptionsMb": [] as [Int],
        ])
        #expect(oversized.limits.maxMemoryMb == 64 * 1_024)

        let legacy = try CloudVMResizePlanValidator().plan(from: [
            "planId": "team",
            "maxMemoryMb": 32 * 1_024,
        ])
        #expect(legacy.limits.maxMemoryMb == 16 * 1_024)
    }

    /// https://github.com/manaflow-ai/cmux/issues/44362: a team deal up to
    /// 64 GiB / 32 vCPU resized only to 16 GiB / 8 vCPU.
    @Test
    func validatorAllowsATeamDealUpToTheLadderTop() throws {
        let plan = try CloudVMResizePlanValidator().plan(from: [
            "planId": "team",
            "maxMemoryMb": 64 * 1_024,
            "maxVcpus": 32,
            "memoryOptionsMb": [4096, 8192, 16384, 24576, 32768, 65536],
            "lockedMemoryOptionsMb": [] as [Int],
        ])
        #expect(plan.limits.maxMemoryMb == 64 * 1_024)
        #expect(plan.limits.maxVcpus == 32)
        let violation = CloudVMResizePlanValidator().violation(
            target: CloudVMResizeShape(vcpus: 32, memoryMb: 64 * 1_024),
            current: CloudVMResizeShape(vcpus: 8, memoryMb: 16 * 1_024),
            usesResourcePool: false,
            limits: plan.limits
        )
        #expect(violation == nil)
    }

    @Test
    func validatorCapsALegacyServersAdvertisedDiskAtThePlanTable() throws {
        // No lockedMemoryOptionsMb: an older control plane whose ceilings may be stale.
        let pro = try CloudVMResizePlanValidator().plan(from: [
            "planId": "pro",
            "maxDiskMb": 256 * 1_024,
        ])
        let go = try CloudVMResizePlanValidator().plan(from: [
            "planId": "go",
            "maxDiskMb": 128 * 1_024,
        ])
        #expect(pro.limits.maxDiskMb == 128 * 1_024)
        #expect(go.limits.maxDiskMb == 128 * 1_024)
    }

    /// #47612: the server owns plan policy. A current control plane's ceilings
    /// are used as published, so a server-side plan change (raising or
    /// lowering a limit) takes effect without a client release. Only the
    /// provider's largest machine bounds them.
    @Test
    func validatorUsesACurrentServersCeilingsWithoutAClientTable() throws {
        let validator = CloudVMResizePlanValidator()
        let raised = try validator.plan(from: [
            "planId": "go",
            "maxVcpus": 12,
            "maxMemoryMb": 24 * 1_024,
            "maxDiskMb": 192 * 1_024,
            "lockedMemoryOptionsMb": [] as [Int],
        ])
        #expect(raised.limits.maxVcpus == 12)
        #expect(raised.limits.maxMemoryMb == 24 * 1_024)
        #expect(raised.limits.maxDiskMb == 192 * 1_024)

        let lowered = try validator.plan(from: [
            "planId": "max",
            "maxVcpus": 4,
            "maxMemoryMb": 8 * 1_024,
            "maxDiskMb": 32 * 1_024,
            "lockedMemoryOptionsMb": [] as [Int],
        ])
        #expect(lowered.limits.maxVcpus == 4)
        #expect(lowered.limits.maxMemoryMb == 8 * 1_024)
        #expect(lowered.limits.maxDiskMb == 32 * 1_024)

        let unknownPlan = try validator.plan(from: [
            "planId": "enterprise-2027",
            "maxVcpus": 16,
            "maxMemoryMb": 32 * 1_024,
            "maxDiskMb": 256 * 1_024,
            "lockedMemoryOptionsMb": [] as [Int],
        ])
        #expect(unknownPlan.limits.maxVcpus == 16)
        #expect(unknownPlan.limits.maxMemoryMb == 32 * 1_024)
        #expect(unknownPlan.limits.maxDiskMb == 256 * 1_024)

        let overProvider = try validator.plan(from: [
            "planId": "max",
            "maxVcpus": 64,
            "maxMemoryMb": 128 * 1_024,
            "maxDiskMb": 512 * 1_024,
            "lockedMemoryOptionsMb": [] as [Int],
        ])
        #expect(overProvider.limits.maxVcpus == 32)
        #expect(overProvider.limits.maxMemoryMb == 64 * 1_024)
        #expect(overProvider.limits.maxDiskMb == 256 * 1_024)
    }

    /// Every plan's resize ceilings must match /pricing and the server's
    /// `maxMemoryMbForPlan` / `maxVcpusForPlan` / `maxDiskMbForPlan`, both when
    /// the server publishes explicit ceilings and when an older control plane
    /// omits them (#47612: Plus was clamped to a 16 GiB disk).
    @Test(arguments: [
        // planId, vCPU, memory GiB, disk GiB
        ("go", 8, 16, 128),
        ("pro", 8, 16, 128),
        ("team", 8, 16, 128),
        ("founders", 8, 16, 128),
        ("max", 32, 64, 256),
        ("free", 4, 8, 128),
    ])
    func validatorCeilingsMatchPricing(plan: String, vcpus: Int, memoryGiB: Int, diskGiB: Int) throws {
        let validator = CloudVMResizePlanValidator()
        let fallback = try validator.plan(from: ["planId": plan])
        let explicit = try validator.plan(from: [
            "planId": plan,
            "maxVcpus": vcpus,
            "maxMemoryMb": memoryGiB * 1_024,
            "maxDiskMb": diskGiB * 1_024,
            "lockedMemoryOptionsMb": [] as [Int],
        ])
        for limits in [fallback.limits, explicit.limits] {
            #expect(limits.maxVcpus == vcpus, "\(plan)")
            #expect(limits.maxMemoryMb == memoryGiB * 1_024, "\(plan)")
            #expect(limits.maxDiskMb == diskGiB * 1_024, "\(plan)")
        }
    }

    /// #47612: a Plus machine at 4 vCPU / 8 GiB / 32 GiB grows its disk up to
    /// the 128 GiB the plan sells, and only past that hits the plan ceiling.
    @Test
    func plusDiskResizeReachesThePricedCeiling() throws {
        let validator = CloudVMResizePlanValidator()
        let plus = try validator.plan(from: [
            "planId": "go",
            "maxVcpus": 8,
            "maxMemoryMb": 16 * 1_024,
            "maxDiskMb": 128 * 1_024,
            "memoryOptionsMb": [4_096, 8_192, 16_384],
            "lockedMemoryOptionsMb": [24_576, 32_768, 65_536],
        ])
        let current = CloudVMResizeShape(vcpus: 4, memoryMb: 8 * 1_024, diskMb: 32 * 1_024)
        for diskGiB in [36, 64, 128] {
            #expect(validator.violation(
                target: CloudVMResizeShape(diskMb: diskGiB * 1_024),
                current: current,
                usesResourcePool: true,
                limits: plus.limits
            ) == nil, "\(diskGiB) GiB")
        }
        #expect(validator.violation(
            target: CloudVMResizeShape(diskMb: 132 * 1_024),
            current: current,
            usesResourcePool: true,
            limits: plus.limits
        ) == .planLimit(resource: .disk, requested: 132 * 1_024, maximum: 128 * 1_024))
        #expect(validator.violation(
            target: CloudVMResizeShape(vcpus: 8, memoryMb: 16 * 1_024),
            current: current,
            usesResourcePool: true,
            limits: plus.limits
        ) == nil)
    }

    @Test
    func validatorRejectsPartiallyPopulatedPool() {
        #expect(throws: CloudVMResizePlanError.incompleteCapacityData) {
            try CloudVMResizePlanValidator().plan(from: [
                "planId": "pro",
                "poolVcpus": 20,
                "poolMemoryMb": 40 * 1024,
                "usedVcpus": 16,
            ])
        }
    }

    @Test
    func validatorRejectsMalformedOrOrphanedPoolUsage() {
        let validator = CloudVMResizePlanValidator()
        for limits in [
            ["planId": "pro", "poolVcpus": 20, "poolMemoryMb": 40 * 1_024, "usedVcpus": "unknown", "usedMemoryMb": 0] as [String: Any],
            ["planId": "pro", "usedVcpus": 0, "usedMemoryMb": 0] as [String: Any],
        ] {
            #expect(throws: CloudVMResizePlanError.incompleteCapacityData) {
                try validator.plan(from: limits)
            }
        }
    }

    @Test
    func validatorAcceptsZeroPoolUsage() throws {
        let plan = try CloudVMResizePlanValidator().plan(from: [
            "planId": "pro",
            "poolVcpus": 20,
            "poolMemoryMb": 40 * 1_024,
            "usedVcpus": 0,
            "usedMemoryMb": 0,
        ])
        #expect(plan.limits.resourcePool?.usedVcpus == 0)
        #expect(plan.limits.resourcePool?.usedMemoryMb == 0)
    }

    @Test
    func plansWithoutAPoolAndOlderServersDecodeNoPool() {
        #expect(CloudVMResourcePool(limits: ["planId": "go", "poolVcpus": NSNull(), "poolMemoryMb": NSNull()]) == nil)
        #expect(CloudVMResourcePool(limits: ["planId": "pro", "maxActiveVms": 5]) == nil)
        // A pool without usage is incomplete, so the client must not make
        // resize decisions from an invented empty usage readout.
        #expect(CloudVMResourcePool(limits: ["poolVcpus": 80, "poolMemoryMb": 163840]) == nil)
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
    func decodesCreateReceiptSessionAndSeparateResourceFields() throws {
        let endpoint = try #require(VMClient.decodeCreateAttach([
            "transport": "cmux-remote",
            "route": "ws://10.16.0.9:1337/v1/link",
            "token": "receipt-token",
            "expires_at_unix": 1_800_000_000,
            "session": "cloud",
            "trusted_carrier": true,
        ]))
        #expect(endpoint.session == "cloud")
        #expect(endpoint.token == "receipt-token")
        #expect(endpoint.expiresAtUnix == 1_800_000_000)
        #expect(VMClient.decodeResourceReservation(["vcpus": 4, "memoryMb": 8192]) == CloudVMResourceReservation(vcpus: 4, memoryMb: 8192, diskMb: nil))
    }

    @Test
    func resizeAdmissionSharesPlanAndPoolRules() {
        let pool = CloudVMResourcePool(poolVcpus: 20, poolMemoryMb: 40 * 1024, usedVcpus: 8, usedMemoryMb: 16 * 1024)
        let limits = CloudVMResizeLimits(maxVcpus: 16, maxMemoryMb: 32 * 1024, maxDiskMb: 128 * 1024, resourcePool: pool)
        let current = CloudVMResizeShape(vcpus: 8, memoryMb: 16 * 1024, diskMb: 64 * 1024)

        #expect(CloudVMResizePlanValidator().violation(
            target: CloudVMResizeShape(vcpus: 16),
            current: current,
            usesResourcePool: true,
            limits: limits
        ) == nil)
        #expect(CloudVMResizePlanValidator().violation(
            target: CloudVMResizeShape(vcpus: 32),
            current: current,
            usesResourcePool: true,
            limits: limits
        ) == .planLimit(resource: .vcpus, requested: 32, maximum: 16))
    }

    @Test
    func resizeAdmissionRemovesActiveReservationButNotPausedReservation() {
        let pool = CloudVMResourcePool(poolVcpus: 20, poolMemoryMb: 40 * 1024, usedVcpus: 8, usedMemoryMb: 16 * 1024)
        let limits = CloudVMResizeLimits(maxVcpus: 32, maxMemoryMb: 64 * 1024, maxDiskMb: 256 * 1024, resourcePool: pool)
        let current = CloudVMResizeShape(vcpus: 8, memoryMb: 16 * 1024)
        let target = CloudVMResizeShape(vcpus: 16, memoryMb: 32 * 1024)

        #expect(CloudVMResizePlanValidator().violation(target: target, current: current, usesResourcePool: true, limits: limits) == nil)
        #expect(CloudVMResizePlanValidator().violation(target: target, current: current, usesResourcePool: false, limits: limits) == .poolLimit(
            requestedVcpus: 16, requestedMemoryMb: 32 * 1024, freeVcpus: 12, freeMemoryMb: 24 * 1024
        ))
    }

    @Test
    func resizeAdmissionUsesPoolClaimSeparatelyFromLiveShape() {
        // A legacy machine can be measured at 2 vCPUs / 4 GiB while its
        // conservative pool claim is 32 vCPUs / 64 GiB. The aggregate usage
        // must subtract the claim, while grow-only compares against the live
        // shape so a 16 vCPU / 32 GiB target remains admissible.
        let pool = CloudVMResourcePool(poolVcpus: 40, poolMemoryMb: 80 * 1024, usedVcpus: 32, usedMemoryMb: 64 * 1024)
        let limits = CloudVMResizeLimits(maxVcpus: 32, maxMemoryMb: 64 * 1024, maxDiskMb: 256 * 1024, resourcePool: pool)
        let current = CloudVMResizeShape(vcpus: 2, memoryMb: 4 * 1024)
        let claim = CloudVMResizeShape(vcpus: 32, memoryMb: 64 * 1024)

        #expect(CloudVMResizePlanValidator().violation(
            target: CloudVMResizeShape(vcpus: 16, memoryMb: 32 * 1024),
            current: current,
            usesResourcePool: true,
            reservation: claim,
            limits: limits
        ) == nil)
        #expect(CloudVMResizePlanValidator().violation(
            target: CloudVMResizeShape(vcpus: 16, memoryMb: 32 * 1024),
            current: current,
            usesResourcePool: true,
            limits: limits
        ) == .poolLimit(
            requestedVcpus: 16, requestedMemoryMb: 32 * 1024,
            freeVcpus: 10, freeMemoryMb: 20 * 1024
        ))
    }

    @Test
    func activeDiskOnlyResizeDoesNotNeedComputePoolCapacity() {
        let pool = CloudVMResourcePool(poolVcpus: 20, poolMemoryMb: 40 * 1024, usedVcpus: 20, usedMemoryMb: 40 * 1024)
        let limits = CloudVMResizeLimits(maxVcpus: 16, maxMemoryMb: 32 * 1024, maxDiskMb: 128 * 1024, resourcePool: pool)
        let current = CloudVMResizeShape(vcpus: 8, memoryMb: 16 * 1024, diskMb: 64 * 1024)

        #expect(CloudVMResizePlanValidator().violation(
            target: CloudVMResizeShape(diskMb: 128 * 1024),
            current: current,
            usesResourcePool: true,
            limits: limits
        ) == nil)
    }

    @Test
    func resizeAdmissionKeepsGrowOnlySemantics() {
        let limits = CloudVMResizeLimits(maxVcpus: 16, maxMemoryMb: 32 * 1024, maxDiskMb: 128 * 1024)
        let current = CloudVMResizeShape(vcpus: 8, memoryMb: 16 * 1024, diskMb: 64 * 1024)

        #expect(CloudVMResizePlanValidator().violation(
            target: CloudVMResizeShape(memoryMb: 16 * 1024),
            current: current,
            usesResourcePool: false,
            limits: limits
        ) == .notLarger(resource: .memory, requested: 16 * 1024, current: 16 * 1024))
    }

    @Test
    func unchangedDimensionMayAccompanyGrowth() {
        let limits = CloudVMResizeLimits(maxVcpus: 16, maxMemoryMb: 32 * 1024, maxDiskMb: 128 * 1024)
        let current = CloudVMResizeShape(vcpus: 8, memoryMb: 16 * 1024, diskMb: 64 * 1024)

        #expect(CloudVMResizePlanValidator().violation(
            target: CloudVMResizeShape(vcpus: 8, memoryMb: 24 * 1024),
            current: current,
            usesResourcePool: false,
            limits: limits
        ) == nil)
    }

    @Test
    func booleanCapacityValuesAreRejected() {
        #expect(CloudVMResizePlanValidator().positiveLimit(true) == nil)
        #expect(CloudVMResizePlanValidator().positiveLimit(false) == nil)
        #expect(CloudVMResizePlanValidator().positiveLimit(NSNumber(value: true)) == nil)
        #expect(CloudVMResizePlanValidator().positiveLimit(NSNumber(value: false)) == nil)
        #expect(CloudVMResourcePool(limits: ["poolVcpus": true, "poolMemoryMb": 40960]) == nil)
        #expect(CloudVMResourcePool(limits: ["poolVcpus": 20, "poolMemoryMb": false]) == nil)
        #expect(throws: CloudVMResizePlanError.incompleteCapacityData) {
            try CloudVMResizePlanValidator().plan(from: [
                "poolVcpus": 20,
                "poolMemoryMb": 40 * 1_024,
                "usedVcpus": true,
                "usedMemoryMb": 0,
            ])
        }
    }

    @Test
    func oversizedFiniteNumbersAreRejectedWithoutTrapping() {
        let validator = CloudVMResizePlanValidator()
        #expect(validator.positiveLimit(1e100) == nil)
        #expect(validator.positiveLimit(Double.greatestFiniteMagnitude) == nil)
        #expect(validator.positiveLimit(16.0) == 16)
    }

    @Test
    func jsonSerializationKeepsNumericZeroAndOneDistinctFromBooleans() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "trueValue": true,
            "falseValue": false,
            "zero": 0,
            "one": 1,
            "poolVcpus": 20,
            "poolMemoryMb": 40960,
            "usedVcpus": 0,
            "usedMemoryMb": 0,
        ])
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let validator = CloudVMResizePlanValidator()

        #expect(validator.positiveLimit(decoded["trueValue"]) == nil)
        #expect(validator.positiveLimit(decoded["falseValue"]) == nil)
        #expect(validator.positiveLimit(decoded["zero"]) == nil)
        #expect(validator.positiveLimit(decoded["one"]) == 1)

        let pool = try #require(CloudVMResourcePool(limits: decoded))
        #expect(pool.usedVcpus == 0)
        #expect(pool.usedMemoryMb == 0)
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
