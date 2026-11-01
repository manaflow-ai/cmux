import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextDesign
import Foundation
import Testing

@MainActor @Suite(.serialized)
struct CloudLivePreviewTests {
    private static let response = #"{"machine":"vm-one","listening":[22,3000,8080],"previews":[{"port":3000,"url":"https://preview.standin.invalid/__cmux/open?token=temporary","origin":"https://preview.standin.invalid","expiresAt":1999999999999}],"unavailable":[{"port":22,"code":"machine.preview_internal_port"}]}"#

    nonisolated final class PreviewAPI: URLProtocol {
        nonisolated(unsafe) static var seen: [URLRequest] = []
        nonisolated(unsafe) static var response = Data()

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url,
                  let reply = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                              headerFields: ["Content-Type": "application/json"]) else { return }
            Self.seen.append(request)
            client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.response)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func inventory() throws -> CloudMachinePreviews {
        try JSONDecoder().decode(CloudMachinePreviews.self, from: Data(Self.response.utf8))
    }

    private func session() -> URLSession {
        PreviewAPI.seen = []
        PreviewAPI.response = Data(Self.response.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewAPI.self]
        return URLSession(configuration: configuration)
    }

    @Test func refreshUsesNewCloudWithThePersonsAccessAndTeam() async throws {
        let api = CloudAPIClient.workerMachines(baseURL: try #require(URL(string: "https://worker.standin.invalid")),
                                                accessToken: { "person-access" }, teamID: { "team-one" }, session: session())
            .previewClient(baseURL: try #require(URL(string: "https://machines.standin.invalid")))
        let result = try await api.refreshPreviews("vm-one")
        #expect(result.listening == [22, 3000, 8080])
        #expect(result.previews.first?.expiresAt == 1_999_999_999_999)
        let request = try #require(PreviewAPI.seen.first)
        #expect(PreviewAPI.seen.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://machines.standin.invalid/v1/cloud/machines/vm-one/previews/refresh")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer person-access")
        #expect(request.value(forHTTPHeaderField: "x-cmux-team") == "team-one")
        #expect(request.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Cmux-Team-Id") == nil)
    }

    @Test func stagingPreviewsUsePlatformWhileOtherOwnersKeepTheirExistingBrowserRoute() {
        var configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_NEXT_CLOUD_LINK": "app"], process: [:], isDebugBuild: true)
        #expect(configuration.platformPreviewAPIBaseURL(environment: [:])?.absoluteString == "https://cmux-platform-staging.debussy.workers.dev")
        #expect(configuration.platformPreviewAPIBaseURL(environment: ["CMUX_NEXT_FEED_API_URL": "https://other-owner.standin.invalid"]) == nil)
        #expect(configuration.platformPreviewAPIBaseURL(environment: ["CMUX_NEXT_PLATFORM_PREVIEW_API_URL": "https://platform.standin.invalid"])?.host == "platform.standin.invalid")
        for invalid in ["http://platform.standin.invalid", "https://user:secret@platform.standin.invalid", "https://platform.standin.invalid/path"] {
            #expect(configuration.platformPreviewAPIBaseURL(environment: ["CMUX_NEXT_PLATFORM_PREVIEW_API_URL": invalid]) == nil)
        }
        configuration.isProductionAuth = true
        #expect(configuration.platformPreviewAPIBaseURL(environment: [:]) == nil)
        #expect(configuration.platformPreviewAPIBaseURL(environment: ["CMUX_NEXT_PLATFORM_PREVIEW_API_URL": "https://platform.standin.invalid"]) == nil)
        configuration.isProductionAuth = false
        configuration.isDebugBuild = false
        #expect(configuration.platformPreviewAPIBaseURL(environment: [:]) == nil)
        configuration.isDebugBuild = true
        configuration.linkSource = .legacy
        #expect(configuration.platformPreviewAPIBaseURL(environment: [:]) == nil)
    }

    @Test func refreshNeverAddsAPreviewToTheClassicAPI() async {
        let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://classic.standin.invalid"],
                                                       process: [:], isDebugBuild: true)
        let api = CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { "team-one" }, session: session())
        await #expect(throws: CloudAPIError.http(status: 501, code: "machine.previews_unsupported", message: nil)) {
            try await api.refreshPreviews("vm-one")
        }
        #expect(PreviewAPI.seen.isEmpty)
    }

    @Test func browserPathKeepsTheAuthenticationBootstrapAndItsToken() throws {
        let preview = try #require(try inventory().previews.first)
        #expect(try preview.browserURL().absoluteString == preview.url)
        let opened = try preview.browserURL(path: "/docs?q=a&sort=up#part")
        let components = try #require(URLComponents(url: opened, resolvingAgainstBaseURL: false))
        #expect(components.path == "/__cmux/open")
        #expect(components.queryItems?.first(where: { $0.name == "token" })?.value == "temporary")
        #expect(components.queryItems?.first(where: { $0.name == "return_to" })?.value == "/docs?q=a&sort=up#part")
        #expect(components.fragment == nil)
    }

    @Test(arguments: ["http://preview.standin.invalid/", "https://user:secret@preview.standin.invalid/", "file:///tmp/a"])
    func aPreviewNeverOpensAnInsecureOrCredentialBearingURL(url: String) throws {
        var preview = try #require(try inventory().previews.first)
        preview.url = url
        #expect(throws: CloudAPIError.decoding("machine.preview_invalid_url")) { try preview.browserURL() }
    }

    @Test func pickerShowsDetectedOriginsAndOpensTheSelectedPort() throws {
        let spec = CloudHandlers.previewPicker(try inventory(), machineName: "My machine")
        let view = CmuxDialogView(spec: spec)
        #expect(view.setValue(.text("3000"), for: "port"))
        #expect(view.values["port"] == .text("3000"))
        #expect(!view.setValue(.text("22"), for: "port"), "an unavailable listener cannot be opened")
        #expect(spec.defaultButton?.id == "open")
        #expect(spec.lines == ["My machine"])
        guard case .choice(_, _, let options, _) = try #require(spec.fields.first) else {
            Issue.record("no preview chooser")
            return
        }
        #expect(options.map(\.label) == ["3000 · https://preview.standin.invalid"])
        #expect(!options.contains { $0.label.contains("temporary") }, "bootstrap credentials are not picker labels")
    }

    @Test func cliAndMCPReceiveTheDetectedPortsAndPrivateURLs() throws {
        let answer = CloudHandlers.previewAnswer(try inventory())
        #expect(answer.fields["machine_id"] == .string("vm-one"))
        #expect(answer.fields["ports"] == .string("22,3000,8080"))
        #expect(answer.fields["listening"] == .array([.int(22), .int(3000), .int(8080)]))
        #expect(answer.fields["unavailable"] == .array([.object(["port": .int(22), "code": .string("machine.preview_internal_port")])]))
        #expect(answer.text == "3000 → https://preview.standin.invalid/__cmux/open?token=temporary")
    }
}
