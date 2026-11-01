import Foundation
import Testing
@testable import CmuxNextCloud

@Suite struct CloudWorkspaceImportTests {
    private static let machine = "vm_aaaaaaaaaaaaaaaaaaaa"
    private static let carrier = "vm_bbbbbbbbbbbbbbbbbbbb"

    nonisolated final class ImportAPI: URLProtocol {
        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url else { return }
            #expect(request.httpMethod == "POST")
            #expect(url.path == "/v1/workspaces/ws_one/machine/import")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer native-owner")
            let payload = (Self.body(request).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
            #expect(Set(payload.keys) == Set(["carrierMachine", "expectedMachine", "expectedGeneration", "clientKey"]))
            #expect(payload["carrierMachine"] as? String == "vm_bbbbbbbbbbbbbbbbbbbb")
            #expect(payload["expectedMachine"] as? String == "vm_aaaaaaaaaaaaaaaaaaaa")
            #expect(payload["expectedGeneration"] as? Int == 2)
            #expect(payload["clientKey"] as? String == "native-workspace-import-v1")
            var answer: [String: Any] = ["machineId": "vm_aaaaaaaaaaaaaaaaaaaa", "generation": 2,
                "provider": "freestyle-vm-api", "connectionMachine": "vm_bbbbbbbbbbbbbbbbbbbb"]
            switch url.host {
            case "wrong-machine.test": answer["machineId"] = "vm_cccccccccccccccccccc"
            case "wrong-generation.test": answer["generation"] = 3
            case "wrong-carrier.test": answer["connectionMachine"] = "vm_cccccccccccccccccccc"
            case "raw-provider.test": answer["connectionMachine"] = "vm_01abcdefghijklmnopqrstuvwx"
            case "trailing-newline.test": answer["connectionMachine"] = "vm_bbbbbbbbbbbbbbbbbbbb\n"
            default: break
            }
            let status = url.host == "pending.test" ? 503 : 200
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: answer)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        private static func body(_ request: URLRequest) -> Data? {
            if let data = request.httpBody { return data }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

    private func owner(_ host: String) -> CloudTurnRewindClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImportAPI.self]
        return CloudTurnRewindClient(origin: URL(string: "https://\(host)")!, token: { "native-owner" }, transport: URLSession(configuration: config))
    }

    @Test func enrollmentBindsOnlyTheExistingVerifiedCarrier() async throws {
        let connection = try await owner("ready.test").importWorkspace(workspace: "ws_one", machine: Self.machine, carrier: Self.carrier, generation: 2)
        #expect(connection.machineId == Self.machine)
        #expect(connection.connectionMachine == Self.carrier)
        #expect(connection.generation == 2)
    }

    @Test(arguments: ["wrong-machine.test", "wrong-generation.test", "wrong-carrier.test", "raw-provider.test", "trailing-newline.test", "pending.test"])
    func uncertainOrMismatchedEnrollmentCannotAuthorizeAttachment(host: String) async {
        await #expect(throws: CloudTurnRewindClient.Failure.self) {
            try await owner(host).importWorkspace(workspace: "ws_one", machine: Self.machine, carrier: Self.carrier, generation: 2)
        }
    }
}
