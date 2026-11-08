import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// `cloud resize-machine --disk GIB` grows a machine's disk (the daemon's `cloud.vm.resize` storageMb),
/// alone or with `--size` in the same call; the body carries only the dimensions given.
@Suite struct CloudResizeDiskTests {
    let fake = FakeCloudAPI { _ in .null }

    private func api() -> CloudAPIClient { fake.classic() }

    /// The one call's args, without its machine id.
    private var body: [String: JSONValue] {
        var args = fake.seen.first?.args ?? [:]
        args["id"] = nil
        return args
    }

    private func request(_ arguments: [String: ActionValue]) throws -> CloudResizeRequest {
        try CloudResizeRequest(ActionInvocation(target: ActionTargetRef(kind: .machine, id: "vm-1"), arguments: arguments, origin: .cli))
    }

    @Test func aDiskOnlyResizeSendsOnlyStorage() async throws {
        let request = try request(["disk": .int(100)])
        try await api().resize("vm-1", cpu: request.cpu, memoryMb: request.memoryMb, storageMb: request.storageMb)
        #expect(fake.operations == ["cloud.vm.resize"])
        #expect(fake.seen.first?.args["id"]?.stringValue == "vm-1")
        #expect(body.count == 1)
        #expect(body["storageMb"]?.intValue == 100 * 1024)
    }

    @Test func sizeAndDiskGoInOneCall() async throws {
        let request = try request(["size": .string("large"), "disk": .string("100")])
        try await api().resize("vm-1", cpu: request.cpu, memoryMb: request.memoryMb, storageMb: request.storageMb)
        #expect(fake.seen.count == 1)
        #expect(body["cpu"]?.intValue == 8)
        #expect(body["memoryMb"]?.intValue == 16384)
        #expect(body["storageMb"]?.intValue == 102_400)
        #expect(request.fields == ["size": .string("large"), "disk_gib": .int(100)])
    }

    @Test func aSizeOnlyResizeSendsNoStorage() async throws {
        let request = try request(["size": .string("small")])
        try await api().resize("vm-1", cpu: request.cpu, memoryMb: request.memoryMb, storageMb: request.storageMb)
        #expect(body["cpu"]?.intValue == 2)
        #expect(body["memoryMb"]?.intValue == 4096)
        #expect(body["storageMb"] == nil)
        #expect(request.fields == ["size": .string("small")])
    }

    @Test(arguments: [
        [:],
        ["disk": ActionValue.int(0)],
        ["disk": .int(-4)],
        ["disk": .int(6)],
        ["disk": .int(260)],
        ["disk": .int(Int.max)],
        ["disk": .string("9223372036854775804")],
        ["disk": .string("1.5")],
        ["disk": .string("lots")],
        ["disk": .bool(true)],
        ["size": .string("huge")],
        ["size": .string("large"), "disk": .int(0)],
    ] as [[String: ActionValue]])
    func refusesNeitherOrABadValue(arguments: [String: ActionValue]) {
        #expect(throws: ActionFailure.self) { try request(arguments) }
    }

    @Test func theCatalogTakesSizeOrDisk() throws {
        let resize = try #require(ActionCatalog.all.first { $0.id == "cloudResizeMachine" })
        #expect(resize.cliName == "cloud resize-machine")
        #expect(resize.arguments.map(\.name) == ["size", "disk"])
        #expect(resize.arguments.allSatisfy { !$0.isRequired })
        // The right-click submenu still lists the sizes.
        guard case .enumeration(let cases) = resize.arguments.first?.kind else {
            Issue.record("size is no longer a choice")
            return
        }
        #expect(cases.map(\.value) == ["small", "medium", "large", "xlarge"])
    }
}
