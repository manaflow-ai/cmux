import CmuxNextCloudUI
import CmuxNextCloud
import CmuxNextDesign
import Testing
import Foundation

/// New Cloud Workspace's machine size: the plan's sizes from `GET /api/vm`'s `limits`, with the
/// server's rate where a listed machine of that size has one, and the pick sent as `memoryMb`.
@Suite("Cloud workspace setup size")
struct CloudWorkspaceSetupSizeTests {
    private static let english = Locale(identifier: "en_US")

    private static func limits(_ json: String) throws -> CloudMachineLimits {
        try JSONDecoder().decode(CloudMachineLimits.self, from: Data(json.utf8))
    }

    private static func machine(_ id: String, cpu: Int, memoryMb: Int, rate: Double?) throws -> CloudMachine {
        let rateField = rate.map { #","hourlyRateUsd":\#($0)"# } ?? ""
        let json = #"{"id":"\#(id)","provider":"freestyle","status":"running","size":{"cpu":\#(cpu),"memoryMb":\#(memoryMb)}\#(rateField)}"#
        return try JSONDecoder().decode(CloudMachine.self, from: Data(json.utf8))
    }

    private static let planLimits = #"{"maxActiveVms":5,"activeVmCount":1,"planId":"pro","memoryOptionsMb":[16384,4096,8192],"vcpusByMemoryMb":{"4096":2,"8192":4,"16384":8}}"#

    @Test func limitsReadThePlanSizesSmallestFirst() throws {
        let limits = try Self.limits(Self.planLimits)
        #expect(limits.memoryOptionsMb == [4096, 8192, 16384])
        #expect(limits.vcpusByMemoryMb == [4096: 2, 8192: 4, 16384: 8])
        #expect(limits.maxActiveVms == 5)
    }

    @Test func malformedSizeFieldsKeepTheCap() throws {
        let limits = try Self.limits(#"{"maxActiveVms":3,"activeVmCount":0,"memoryOptionsMb":"lots","vcpusByMemoryMb":[1]}"#)
        #expect(limits.maxActiveVms == 3)
        #expect(limits.memoryOptionsMb.isEmpty)
        #expect(limits.vcpusByMemoryMb.isEmpty)
    }

    @Test func aMalformedCountKeepsThePlanSizes() throws {
        let limits = try Self.limits(#"{"maxActiveVms":"five","activeVmCount":null,"memoryOptionsMb":[4096],"vcpusByMemoryMb":{"4096":2}}"#)
        #expect(limits.maxActiveVms == nil)
        #expect(limits.activeVmCount == 0)
        #expect(limits.memoryOptionsMb == [4096])
    }

    @Test func aRateComesOnlyFromAListedMachineOfTheSameSize() throws {
        let limits = try Self.limits(Self.planLimits)
        let machines = [
            try Self.machine("vm_a", cpu: 4, memoryMb: 8192, rate: 0.26),
            // Same memory, other vCPUs: not this size, so its rate is not borrowed.
            try Self.machine("vm_b", cpu: 2, memoryMb: 16384, rate: 0.4),
            try Self.machine("vm_c", cpu: 2, memoryMb: 4096, rate: nil),
        ]
        let options = CloudWorkspaceSetupWizard.SizeOption.options(limits: limits, machines: machines)
        #expect(options == [
            .init(memoryMb: 4096, vcpus: 2),
            .init(memoryMb: 8192, vcpus: 4, hourlyRateUsd: 0.26),
            .init(memoryMb: 16384, vcpus: 8),
        ])
    }

    @Test func machinesOfOneSizeWithDifferentRatesShowNoRate() throws {
        let limits = try Self.limits(Self.planLimits)
        let machines = [try Self.machine("vm_a", cpu: 4, memoryMb: 8192, rate: 0.26), try Self.machine("vm_b", cpu: 4, memoryMb: 8192, rate: 0.3)]
        let options = CloudWorkspaceSetupWizard.SizeOption.options(limits: limits, machines: machines)
        #expect(options[1].hourlyRateUsd == nil)
    }

    @Test func noLimitsOffersNoSize() {
        #expect(CloudWorkspaceSetupWizard.SizeOption.options(limits: nil, machines: []).isEmpty)
    }

    @Test func labelsShowWhatTheServerSent() {
        #expect(CloudWorkspaceSetupWizard.SizeOption(memoryMb: 8192, vcpus: 4, hourlyRateUsd: 0.26).label(locale: Self.english) == "4 vCPU, 8 GB memory · $0.26/h")
        #expect(CloudWorkspaceSetupWizard.SizeOption(memoryMb: 4096, vcpus: 2).label(locale: Self.english) == "2 vCPU, 4 GB memory")
        #expect(CloudWorkspaceSetupWizard.SizeOption(memoryMb: 1536).label(locale: Self.english) == "1.5 GB memory")
    }

    private static let sizes: [CloudWorkspaceSetupWizard.SizeOption] = [.init(memoryMb: 4096, vcpus: 2), .init(memoryMb: 8192, vcpus: 4)]

    private static func sizeChoice(_ spec: CmuxDialogSpec) -> (options: [String], selected: String?)? {
        for field in spec.fields {
            if case .choice(let id, _, let options, let selected) = field, id == "size" { return (options.map(\.value), selected) }
        }
        return nil
    }

    @MainActor
    @Test func theDialogOffersThePlanSizesWithTheSmallestSelected() throws {
        let choice = try #require(Self.sizeChoice(CloudWorkspaceSetupWizard.setupDialogSpec(sizes: Self.sizes)))
        #expect(choice.options == ["4096", "8192"])
        #expect(choice.selected == "4096")
    }

    @MainActor
    @Test func aChatThatSizesItsMachineIsOfferedFirst() throws {
        let choice = try #require(Self.sizeChoice(CloudWorkspaceSetupWizard.setupDialogSpec(sizes: Self.sizes, autosized: true)))
        #expect(choice.options == ["auto", "4096", "8192"])
        #expect(choice.selected == "auto")
    }

    @MainActor
    @Test func noSizesShowsNoSizeChoice() {
        #expect(Self.sizeChoice(CloudWorkspaceSetupWizard.setupDialogSpec()) == nil)
    }

    @MainActor
    @Test(arguments: [("8192", Optional(8192)), ("auto", nil), ("65536", nil), ("big", nil)])
    func thePickedSizeIsSentAsTheCreateMemory(answer: String, expected: Int?) async throws {
        let plan = try #require(try await CloudWorkspaceSetupWizard().choosePlan(availability: .available, scopeIsCurrent: { true },
            sizes: Self.sizes, present: { _ in
                CmuxDialogAnswer(button: "create", role: .default, values: ["source": .text("empty"), "size": .text(answer)])
            }))
        #expect(plan.memoryMb == expected)
        #expect(plan.request.memoryMb == expected)
    }
}
