import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemonService
import Foundation
import Testing

/// `cloud resize-machine --disk GIB` grows a machine's disk (POST /api/vm/{id}/resize's storageMb),
/// alone or with `--size` in the same call; the body carries only the dimensions given.
/// The route and body are cmux-tui's (`cli/cloud_api/tests.rs`); this checks what the app hands it.
@Suite(.serialized)
struct CloudResizeDiskTests {
    /// What `resize` handed cmux, one call.
    private func resized(_ request: CloudResizeRequest) async throws -> [String: Any] {
        let cmux = try FakeBundledCmux()
        defer { cmux.remove() }
        try await cmux.classic().resize("vm-1", cpu: request.cpu, memoryMb: request.memoryMb, storageMb: request.storageMb)
        #expect(cmux.calls == ["vm.resize"])
        var args = cmux.request(1)["args"] as? [String: Any] ?? [:]
        #expect(args.removeValue(forKey: "id") as? String == "vm-1")
        return args
    }

    private func request(_ arguments: [String: ActionValue]) throws -> CloudResizeRequest {
        try CloudResizeRequest(ActionInvocation(target: ActionTargetRef(kind: .machine, id: "vm-1"), arguments: arguments, origin: .cli))
    }

    @Test func aDiskOnlyResizeSendsOnlyStorage() async throws {
        let body = try await resized(try request(["disk": .int(100)]))
        #expect(body.count == 1)
        #expect(body["storageMb"] as? Int == 100 * 1024)
    }

    @Test func sizeAndDiskGoInOneCall() async throws {
        let request = try request(["size": .string("large"), "disk": .string("100")])
        let body = try await resized(request)
        #expect(body["cpu"] as? Int == 8)
        #expect(body["memoryMb"] as? Int == 16384)
        #expect(body["storageMb"] as? Int == 102_400)
        #expect(request.fields == ["size": .string("large"), "disk_gib": .int(100)])
    }

    @Test func aSizeOnlyResizeSendsNoStorage() async throws {
        let request = try request(["size": .string("small")])
        let body = try await resized(request)
        #expect(body["cpu"] as? Int == 2)
        #expect(body["memoryMb"] as? Int == 4096)
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
