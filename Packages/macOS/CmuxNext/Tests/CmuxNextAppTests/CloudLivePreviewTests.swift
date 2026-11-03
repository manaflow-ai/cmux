import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDesign
import CmuxNextWakeups
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

    /// A subprocess stand-in records both channels without seeing any credential in argv.
    private func previewCLI(reply: String) throws -> (binary: URL, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preview-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("cmux")
        let script = #"""
        #!/bin/sh
        d=${0%/*}
        cat > "$d/stdin"
        printf '%s\n' "$@" > "$d/argv"
        cat "$d/reply"
        """#
        try Data(script.utf8).write(to: binary)
        try Data(reply.utf8).write(to: folder.appendingPathComponent("reply"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return (binary, folder)
    }

    private func previewAPI(binary: URL, folder: URL) throws -> CloudAPIClient {
        CloudAPIClient.workerMachines(baseURL: try #require(URL(string: "https://worker.standin.invalid")),
                                      accessToken: { "person-access" }, teamID: { "team-one" }, session: session(),
                                      appVersion: "preview-test", machineIO: CloudMachineIO(binary: binary,
                                        cacheDirectory: folder, work: BackgroundWork()))
            .previewClient(baseURL: try #require(URL(string: "https://machines.standin.invalid")))
    }

    @Test func sharingForwardsTheAccountAndAllAudiencesToRustOnStdin() async throws {
        for audience in ["link", "team", "user"] {
            let (binary, folder) = try previewCLI(reply: #"{"ok":true,"value":{"url":"https://shared.standin.invalid/preview/shared-one"}}"#)
            defer { try? FileManager.default.removeItem(at: folder) }
            let api = try previewAPI(binary: binary, folder: folder)
            let result = try await api.sharePreview("vm-one", port: 3000, audience: audience, userID: "user-recipient")
            #expect(result.url == "https://shared.standin.invalid/preview/shared-one")
            let data = try Data(contentsOf: folder.appendingPathComponent("stdin"))
            let request = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(request["api"] as? String == "https://machines.standin.invalid")
            #expect(request["machine"] as? String == "vm-one")
            #expect(request["credential"] as? String == "person-access")
            #expect(request["team"] as? String == "team-one")
            #expect(request["app_version"] as? String == "preview-test")
            let ask = try #require(request["ask"] as? [String: Any])
            #expect(ask["operation"] as? String == "share")
            #expect(ask["port"] as? Int == 3000)
            #expect(ask["bootstrap"] as? Bool == false)
            if audience == "user" {
                #expect(ask["audience"] as? [String: String] == ["user": "user-recipient"])
            } else {
                #expect(ask["audience"] as? String == audience)
            }
            let argv = try String(contentsOf: folder.appendingPathComponent("argv"), encoding: .utf8)
            #expect(argv == "cloud\npreview-account\n", "credentials never go in process arguments")
            #expect(PreviewAPI.seen.isEmpty, "Swift delegates all preview HTTP orchestration to Rust")
        }
    }

    @Test func aRefusedOrMissingRustAnswerNeverRetriesSharingOverHTTP() async throws {
        for reply in [#"{"ok":false,"error":{"code":"preview.share_failed","message":"recipient refused"}}"#, "not json"] {
            let (binary, folder) = try previewCLI(reply: reply)
            defer { try? FileManager.default.removeItem(at: folder) }
            let api = try previewAPI(binary: binary, folder: folder)
            do {
                _ = try await api.sharePreview("vm-one", port: 3000, audience: "link")
                Issue.record("expected the Rust failure to reach the caller")
            } catch let error as CloudAPIError {
                if reply == "not json" {
                    #expect(error.code == "bad_response")
                } else {
                    #expect(error.code == "preview.share_failed")
                    #expect(error.description == "recipient refused")
                }
            }
            #expect(PreviewAPI.seen.isEmpty)
        }
    }

    @Test func stagingAndDevelopmentPreviewsUseTheirPlatformWhileOtherOwnersKeepTheirExistingBrowserRoute() {
        var configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_NEXT_CLOUD_LINK": "app"], process: [:], isDebugBuild: true)
        #expect(configuration.platformPreviewAPIBaseURL(environment: [:])?.absoluteString == "https://cmux-platform-development.debussy.workers.dev")
        #expect(configuration.platformPreviewAPIBaseURL(environment: ["CMUX_NEXT_FEED_API_URL": "https://cloud-api-staging.cmux.dev"])?.absoluteString == "https://cmux-platform-staging.debussy.workers.dev")
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

        let signedDev = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: [:], process: [:], isDebugBuild: false)
        #expect(signedDev.platformPreviewAPIBaseURL()?.absoluteString == "https://cmux-platform-development.debussy.workers.dev")
    }

    @Test func artifactsOriginFollowsCloudEnvironmentAndDebugOverrides() {
        let production = CloudConfiguration.resolve(bundleID: nil, bundled: [:], process: [:], isDebugBuild: false)
        #expect(production.artifactsAPIBaseURL(environment: [:])?.absoluteString == "https://cmux-platform.debussy.workers.dev")
        #expect(production.artifactsAPIBaseURL(environment: ["CMUX_NEXT_ARTIFACTS_API_URL": "https://evil.invalid"])?.absoluteString == "https://cmux-platform.debussy.workers.dev")

        let development = CloudConfiguration.resolve(bundleID: nil, bundled: [:], process: [:], isDebugBuild: true)
        #expect(development.artifactsAPIBaseURL(environment: [:])?.absoluteString == "https://cmux-platform-development.debussy.workers.dev")
        #expect(development.artifactsAPIBaseURL(environment: ["CMUX_NEXT_ARTIFACTS_API_URL": "https://cmux-platform-staging.debussy.workers.dev"])?.absoluteString == "https://cmux-platform-staging.debussy.workers.dev")
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
        let spec = CloudPreviewUI.previewPicker(try inventory(), machineName: "My machine")
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

    @Test func pickerOffersShareAndSharePickerDefaultsToPrivateLink() throws {
        let spec = CloudPreviewUI.previewPicker(try inventory(), machineName: "My machine")
        #expect(spec.buttons.map(\.id) == ["cancel", "share", "open"])
        #expect(spec.defaultButton?.id == "open")
        let share = CloudPreviewUI.sharePicker(machineName: "My machine")
        #expect(share.defaultButton?.id == "share")
        #expect(share.identifier == "cmux.dialog.cloud.sharePreview")
        guard case .choice(_, _, let options, let selected) = try #require(share.fields.first) else {
            Issue.record("no audience chooser")
            return
        }
        #expect(options.map(\.value) == ["link", "team", "user"])
        #expect(selected == "link")
        #expect(share.fields.contains { field in
            if case .text(let id, _, _, _, _) = field { return id == "user_id" }
            return false
        })
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
