import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemonService
import Foundation
import Testing

/// `cloud resize-machine --disk GIB` grows a machine's disk (POST /api/vm/{id}/resize's storageMb),
/// alone or with `--size` in the same call; the body carries only the dimensions given.
@Suite(.serialized)
struct CloudResizeDiskTests {
    nonisolated final class ResizeRoute: URLProtocol {
        nonisolated(unsafe) static var seen: [(method: String, path: String, body: [String: Any]?)] = []

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            let body = Self.body(of: request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            Self.seen.append((request.httpMethod ?? "", url.path, body))
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"id":"vm-1","state":"running"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// URLSession moves a body into a stream before a protocol sees it.
        private static func body(of request: URLRequest) -> Data? {
            if let data = request.httpBody { return data }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

    private func api() -> CloudAPIClient {
        let configuration = CloudConfiguration.resolve(
            bundleID: nil,
            bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
            process: [:],
            isDebugBuild: true
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ResizeRoute.self]
        return CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { "team-1" },
                              session: URLSession(configuration: sessionConfiguration))
    }

    private func request(_ arguments: [String: ActionValue]) throws -> CloudResizeRequest {
        try CloudResizeRequest(ActionInvocation(target: ActionTargetRef(kind: .machine, id: "vm-1"), arguments: arguments, origin: .cli))
    }

    @Test func aDiskOnlyResizeSendsOnlyStorage() async throws {
        ResizeRoute.seen = []
        let request = try request(["disk": .int(100)])
        try await api().resize("vm-1", cpu: request.cpu, memoryMb: request.memoryMb, storageMb: request.storageMb)
        #expect(ResizeRoute.seen.map(\.method) == ["POST"])
        #expect(ResizeRoute.seen.map(\.path) == ["/api/vm/vm-1/resize"])
        let body = try #require(ResizeRoute.seen.first?.body)
        #expect(body.count == 1)
        #expect(body["storageMb"] as? Int == 100 * 1024)
    }

    @Test func sizeAndDiskGoInOneCall() async throws {
        ResizeRoute.seen = []
        let request = try request(["size": .string("large"), "disk": .string("100")])
        try await api().resize("vm-1", cpu: request.cpu, memoryMb: request.memoryMb, storageMb: request.storageMb)
        #expect(ResizeRoute.seen.count == 1)
        let body = try #require(ResizeRoute.seen.first?.body)
        #expect(body["cpu"] as? Int == 8)
        #expect(body["memoryMb"] as? Int == 16384)
        #expect(body["storageMb"] as? Int == 102_400)
        #expect(request.fields == ["size": .string("large"), "disk_gib": .int(100)])
    }

    @Test func aSizeOnlyResizeSendsNoStorage() async throws {
        ResizeRoute.seen = []
        let request = try request(["size": .string("small")])
        try await api().resize("vm-1", cpu: request.cpu, memoryMb: request.memoryMb, storageMb: request.storageMb)
        let body = try #require(ResizeRoute.seen.first?.body)
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
