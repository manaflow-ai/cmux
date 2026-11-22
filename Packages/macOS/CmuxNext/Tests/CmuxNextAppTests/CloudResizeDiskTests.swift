import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// `cloud resize-machine --disk GIB` grows a machine's disk (the app server's `cloud.machine.resize`
/// `size.disk_mb`), alone or with `--size` in the same call; the args carry only the dimensions given.
@Suite
struct CloudResizeDiskTests {
    private func request(_ arguments: [String: ActionValue]) throws -> CloudHandlers.Resize {
        try CloudHandlers.resizeRequest(ActionInvocation(target: ActionTargetRef(kind: .machine, id: "vm-1"), arguments: arguments, origin: .cli))
    }

    private func size(_ request: CloudHandlers.Resize) throws -> [String: JSONValue] {
        let args = CloudHandlers.resizeArgs(request, machine: "vm-1")
        #expect(args["machine"]?.stringValue == "vm-1")
        guard case .object(let size)? = args["size"] else { Issue.record("no size in \(args)"); return [:] }
        return size
    }

    @Test func aDiskOnlyResizeSendsOnlyTheDisk() throws {
        let size = try size(try request(["disk": .int(100)]))
        #expect(size == ["disk_mb": .number(100 * 1024)])
    }

    @Test func sizeAndDiskGoInOneCall() throws {
        let request = try request(["size": .string("large"), "disk": .string("100")])
        #expect(try size(request) == ["cpu": .number(8), "memory_mb": .number(16384), "disk_mb": .number(102_400)])
        #expect(request.fields == ["size": .string("large"), "disk_gib": .int(100)])
    }

    @Test func aSizeOnlyResizeSendsNoDisk() throws {
        let request = try request(["size": .string("small")])
        #expect(try size(request) == ["cpu": .number(2), "memory_mb": .number(4096)])
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
