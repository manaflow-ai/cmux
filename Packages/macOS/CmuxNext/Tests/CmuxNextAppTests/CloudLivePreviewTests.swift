import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDesign
import Foundation
import Testing

@MainActor @Suite(.serialized)
struct CloudLivePreviewTests {
    nonisolated private static let response = #"{"machine":"vm-one","listening":[22,3000,8080],"previews":[{"port":3000,"url":"https://preview.standin.invalid/__cmux/open?token=temporary","origin":"https://preview.standin.invalid","expiresAt":1999999999999}],"unavailable":[{"port":22,"code":"machine.preview_internal_port"}]}"#

    private func inventory() throws -> CloudMachinePreviews {
        try JSONDecoder().decode(CloudMachinePreviews.self, from: Data(Self.response.utf8))
    }

    /// The refresh is the daemon's `cloud.previews.refresh` (cmux-cloud-api `previews.rs`) at the platform
    /// preview origin, as the person's access in their team; the platform's catalog comes back as its body.
    @Test func refreshUsesNewCloudWithThePersonsAccessAndTeam() async throws {
        let daemon = CloudAPIClientRunTests.FakeDaemon { _, _, _ in #"{"ok":true,"body":\#(Self.response)}"# }
        var worker = CloudAPIClient.workerMachines(baseURL: try #require(URL(string: "https://worker.standin.invalid")),
                                                   accessToken: { "person-access" }, teamID: { "team-one" })
        worker.daemon.daemonCall = { input, _ in try daemon.run(input) }
        let api = worker.previewClient(baseURL: try #require(URL(string: "https://machines.standin.invalid")))
        let result = try await api.refreshPreviews("vm-one")
        #expect(result.listening == [22, 3000, 8080])
        #expect(result.previews.first?.expiresAt == 1_999_999_999_999)
        #expect(daemon.requests.count == 1)
        let request = try #require(daemon.requests.first)
        #expect(request["call"] as? String == "previews.refresh")
        #expect(request["api"] as? String == "https://machines.standin.invalid")
        #expect(request["credential"] as? String == "person-access")
        #expect(request["team"] as? String == "team-one")
        #expect(request["refresh"] == nil)
        #expect((request["args"] as? [String: Any])?["machine"] as? String == "vm-one")
    }

    @Test func selectedBackendSuppliesPreviewAndArtifactOrigins() {
        let configuration = CloudConfiguration.resolve(bundleID: nil,
            bundled: ["CMUX_NEXT_PLATFORM_PREVIEW_API_URL": "https://platform.fixture.invalid"], process: [:], isDebugBuild: true)
        #expect(configuration.platformPreviewAPIBaseURL() == URL(string: "https://platform.fixture.invalid"))
        #expect(configuration.artifactsAPIBaseURL() == URL(string: "https://platform.fixture.invalid"))
    }

    @Test func artifactsOriginFollowsCloudEnvironmentAndDebugOverrides() {
        let selected = CloudConfiguration.resolve(bundleID: nil,
            bundled: ["CMUX_NEXT_PLATFORM_PREVIEW_API_URL": "https://platform.fixture.invalid"], process: [:], isDebugBuild: false)
        #expect(selected.artifactsAPIBaseURL() == URL(string: "https://platform.fixture.invalid"))
    }

    @Test func selectedBackendOwnsPreviewRouting() {
        let configuration = CloudConfiguration.resolve(bundleID: nil,
            bundled: ["CMUX_VM_API_BASE_URL": "https://backend.fixture.invalid",
                      "CMUX_NEXT_PLATFORM_PREVIEW_API_URL": "https://platform.fixture.invalid"],
            process: [:], isDebugBuild: true)
        #expect(configuration.platformPreviewAPIBaseURL() == URL(string: "https://platform.fixture.invalid"))
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
        let spec = CloudPreviewPresentation(try inventory()).picker(machineName: "My machine", cancelTitle: "Cancel")
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        let id = center.present(spec, in: .app) { _ in }
        defer { center.dismissAll() }
        #expect(center.setValue(.text("3000"), for: "port", in: id))
        #expect(center.record(id)?.values["port"] == .text("3000"))
        #expect(!center.setValue(.text("22"), for: "port", in: id), "an unavailable listener cannot be opened")
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
