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
            let firstImport = url.host?.hasPrefix("first-") == true
            #expect(payload["expectedMachine"] as? String == (firstImport ? "vm_bbbbbbbbbbbbbbbbbbbb" : "vm_aaaaaaaaaaaaaaaaaaaa"))
            #expect(payload["expectedGeneration"] as? Int == (firstImport ? 0 : 2))
            #expect(payload["clientKey"] as? String == "native-workspace-import-v1")
            var answer: [String: Any] = ["machineId": "vm_aaaaaaaaaaaaaaaaaaaa", "generation": 2,
                "reconnectRequired": true, "provider": "freestyle-cloud", "connectionMachine": "vm_bbbbbbbbbbbbbbbbbbbb"]
            if firstImport { answer["machineId"] = "vm_bbbbbbbbbbbbbbbbbbbb" }
            switch url.host {
            case "first-ready.test": answer["generation"] = 1
            case "first-zero.test": answer["generation"] = 0
            case "wrong-machine.test": answer["machineId"] = "vm_cccccccccccccccccccc"
            case "wrong-generation.test": answer["generation"] = 3
            case "wrong-carrier.test": answer["connectionMachine"] = "vm_cccccccccccccccccccc"
            case "raw-provider.test": answer["connectionMachine"] = "vm_01abcdefghijklmnopqrstuvwx"
            case "trailing-newline.test": answer["connectionMachine"] = "vm_bbbbbbbbbbbbbbbbbbbb\n"
            case "ready-repeat.test": answer["reconnectRequired"] = false
            case "missing-reconnect.test": answer.removeValue(forKey: "reconnectRequired")
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

    @Test func turnOwnerUsesItsConfiguredEnvironment() {
        var configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_NEXT_CLOUD_LINK": "app"], process: [:], isDebugBuild: true)
        let development = ["CMUX_NEXT_FEED_API_URL": "https://cmux-api-development.debussy.workers.dev"]
        #expect(configuration.turnAPIBaseURL(environment: [:]).absoluteString == "https://cmux-platform-staging.debussy.workers.dev")
        #expect(configuration.turnAPIBaseURL(environment: development).absoluteString == "https://cmux-platform-development.debussy.workers.dev")
        configuration.isProductionAuth = true
        #expect(configuration.turnAPIBaseURL(environment: [:]).absoluteString == "https://cmux-platform-production.debussy.workers.dev")
        #expect(configuration.turnAPIBaseURL(environment: development).absoluteString == "https://cmux-platform-production.debussy.workers.dev")
    }

    @Test(arguments: ["https://other-owner.invalid", "http://cmux-api-development.debussy.workers.dev",
                      "https://cmux-api-development.debussy.workers.dev:8443", "https://cmux-api-development.debussy.workers.dev/path"])
    func unknownOwnerCannotMintOrSendATurnToken(origin: String) async {
        let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_NEXT_CLOUD_LINK": "app"], process: [:], isDebugBuild: true)
        let client = CloudTurnRewindClient(origin: configuration.turnAPIBaseURL(environment: ["CMUX_NEXT_FEED_API_URL": origin])) {
            Issue.record("An unknown owner origin must fail before minting a token")
            return "must-not-be-sent"
        }
        await #expect(throws: CloudTurnRewindClient.Failure.self) { try await client.state(workspace: "ws_one") }
    }

    @Test func legacyAndReleaseBuildsCannotSelectADebugTurnOrigin() {
        var configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_NEXT_CLOUD_LINK": "app"], process: [:], isDebugBuild: true)
        configuration.isDebugBuild = false
        #expect(configuration.turnAPIBaseURL(environment: ["CMUX_NEXT_FEED_API_URL": "https://cmux-api-development.debussy.workers.dev"]).absoluteString == "https://cmux-platform-staging.debussy.workers.dev")
        configuration.linkSource = .legacy
        #expect(configuration.turnAPIBaseURL(environment: [:]).isFileURL)
    }

    @Test func enrollmentBindsOnlyTheExistingVerifiedCarrier() async throws {
        let enrollment = try await owner("ready.test").importWorkspace(workspace: "ws_one", machine: Self.machine, carrier: Self.carrier, generation: 2)
        let connection = enrollment.connection
        #expect(connection.machineId == Self.machine)
        #expect(connection.connectionMachine == Self.carrier)
        #expect(connection.generation == 2)
        #expect(enrollment.reconnectRequired)
        let repeated = try await owner("ready-repeat.test").importWorkspace(workspace: "ws_one", machine: Self.machine, carrier: Self.carrier, generation: 2)
        #expect(!repeated.reconnectRequired)
    }

    @Test func enrollmentMustStateWhetherItRestartedTheGuest() async {
        await #expect(throws: DecodingError.self) {
            try await owner("missing-reconnect.test").importWorkspace(workspace: "ws_one", machine: Self.machine, carrier: Self.carrier, generation: 2)
        }
    }

    @Test func firstEnrollmentAdoptsCanonicalGeneration() async throws {
        let enrollment = try await owner("first-ready.test").importWorkspace(workspace: "ws_one", machine: Self.carrier, carrier: Self.carrier, generation: 0)
        #expect(enrollment.connection.generation == 1)
        #expect(enrollment.connection.connectionMachine == Self.carrier)
    }

    @Test(arguments: ["first-zero.test", "first-too-new.test"])
    func firstEnrollmentRefusesUnexpectedGeneration(host: String) async {
        await #expect(throws: CloudTurnRewindClient.Failure.self) {
            try await owner(host).importWorkspace(workspace: "ws_one", machine: Self.carrier, carrier: Self.carrier, generation: 0)
        }
    }

    @Test(arguments: ["wrong-machine.test", "wrong-generation.test", "wrong-carrier.test", "raw-provider.test", "trailing-newline.test", "pending.test"])
    func uncertainOrMismatchedEnrollmentCannotAuthorizeAttachment(host: String) async {
        await #expect(throws: CloudTurnRewindClient.Failure.self) {
            try await owner(host).importWorkspace(workspace: "ws_one", machine: Self.machine, carrier: Self.carrier, generation: 2)
        }
    }
}
