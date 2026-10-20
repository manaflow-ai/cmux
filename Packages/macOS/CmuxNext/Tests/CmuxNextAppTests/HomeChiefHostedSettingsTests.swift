import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
@testable import CmuxNextHomeEngine
import CmuxNextHostedChief
import Foundation
import Testing

/// A hosted cloud Chief (no `brain_place`; the Cloud service's brain answers) has settings: the
/// card reads and writes its model and effort through the brain route, never through a paired
/// server. 2026-10-20: a new Chief's card said "The server with this Chief is not connected."
/// and its pickers were empty, since the card looked for the server its brain is placed on.
@MainActor @Suite(.serialized)
struct HomeChiefHostedSettingsTests {
    static let agent = "agent_01JZ0000000000000000000000"
    static let main = "conv_dm_01JZ0000000000000000000000"

    // MARK: Which brain the card talks to

    @Test func aHostedCloudChiefUsesTheCloudBrainRoute() async {
        let services = Self.services()
        services.home.setCloudChiefs(HomeCloudChiefs(hosted: CloudChief(id: Self.agent, displayName: "Chief", isDefault: true,
                                                                        mainConversation: Self.main, rev: 1)))
        let control = HomeChiefControl(services: services, conversation: ConversationID(Self.main), muxHome: Self.home())
        #expect(control.isHosted)
        #expect(control.hostedChiefID == Self.agent)
        #expect(control.engineSource() is HomeChiefHostedEngine)
        // No server to ask: Stop says the cloud has no stop yet, not that a server is missing.
        #expect(await control.stop() == .cloudStopUnsupported)
    }

    @Test func aChiefPlacedOnAServerStaysOnThatServersDaemon() {
        let services = Self.services()
        let placed = CloudChief(id: Self.agent, displayName: "Chief (Mac mini)", isDefault: false, mainConversation: Self.main, rev: 1,
                                brainPlace: .init(host: "host_mini", install: "install_1"))
        services.home.setCloudChiefs(HomeCloudChiefs(placed: placed))
        let control = HomeChiefControl(services: services, conversation: ConversationID(Self.main), muxHome: Self.home())
        #expect(!control.isHosted)
        #expect(control.hostedChiefID == nil)
        #expect(control.engineSource() is HomeChiefRemoteEngine)
    }

    @Test func thisMacsChiefStaysLocal() {
        let services = Self.services()
        let control = HomeChiefControl(services: services, conversation: ConversationID("conv_local"), muxHome: Self.home())
        #expect(!control.isHosted)
        #expect(control.engineSource() is HomeChiefLocalEngine)
    }

    // MARK: The card over the brain route

    @Test func theCardShowsTheCloudBrainsModelAndEffort() async throws {
        let cloud = FakeBrainRoute(config: ["enabled": true, "model": "claude-sonnet-5-5", "effort": "medium"])
        let view = Self.card(cloud)
        await view.use(Self.engine(cloud)).value
        #expect(view.failure.isHidden)
        #expect(view.place.stringValue == HomeEngineStrings.runsInCloud)
        // One engine of its own: no harness to pick.
        #expect(view.harness.superview?.isHidden == true)
        let models = view.model.itemArray.compactMap { $0.representedObject as? String }
        #expect(models == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        #expect(view.model.selectedItem?.representedObject as? String == "claude-sonnet-5-5")
        let efforts = view.effort.itemArray.compactMap { $0.representedObject as? String }
        #expect(efforts == ["off", "minimal", "low", "medium", "high", "xhigh", "max"])
        #expect(view.effort.selectedItem?.representedObject as? String == "medium")
        #expect(view.model.isEnabled && view.effort.isEnabled)
        #expect(cloud.requests.first?.method == "GET")
        #expect(cloud.requests.first?.path == "v1/chiefs/\(Self.agent)/brain")
    }

    @Test func aPickPutsTheModelOnTheBrainRoute() async throws {
        let cloud = FakeBrainRoute(config: ["enabled": true, "model": "claude-opus-5-5", "effort": "low"])
        let view = Self.card(cloud)
        await view.use(Self.engine(cloud)).value
        await view.pick("model", "claude-haiku-5-5").value
        let put = try #require(cloud.requests.last { $0.method == "PUT" })
        #expect(put.method == "PUT")
        #expect(put.path == "v1/chiefs/\(Self.agent)/brain")
        #expect(put.body == ["model": "claude-haiku-5-5"])
        #expect(view.model.selectedItem?.representedObject as? String == "claude-haiku-5-5")
        #expect(view.failure.isHidden)
        // Default sets the brain's own default: the route never clears a field.
        await view.pick("effort", nil).value
        #expect(cloud.requests.last { $0.method == "PUT" }?.body == ["effort": "low"])
    }

    @Test func aRefusedModelSaysWhyAndKeepsWhatTheBrainRuns() async {
        let cloud = FakeBrainRoute(config: ["enabled": true, "model": "claude-opus-5-5", "effort": "low"])
        cloud.refusal = (409, "chief_claude_unavailable", "claude-sonnet-5-5 is not available for this account here")
        let view = Self.card(cloud)
        await view.use(Self.engine(cloud)).value
        await view.pick("model", "claude-sonnet-5-5").value
        #expect(!view.failure.isHidden)
        #expect(view.failure.stringValue.contains("not available for this account"))
        #expect(view.model.selectedItem?.representedObject as? String == "claude-opus-5-5")
    }

    @Test func signedOutAndOfflineSayTheCloudNotAServer() async {
        let signedOut = FakeBrainRoute(config: [:])
        signedOut.failure = HomeChiefHostedEngine.Failure.signedOut
        let view = Self.card(signedOut)
        await view.use(Self.engine(signedOut)).value
        #expect(view.failure.stringValue == HomeEngineStrings.errorSignedOut)
        #expect(!view.model.isEnabled)

        let offline = FakeBrainRoute(config: [:])
        offline.failure = URLError(.notConnectedToInternet)
        let offlineView = Self.card(offline)
        await offlineView.use(Self.engine(offline)).value
        #expect(offlineView.failure.stringValue == HomeEngineStrings.errorCloudUnreachable)
        #expect(offlineView.failure.stringValue != HomeEngineStrings.errorUnreachable)
    }

    @Test func aBrainThatIsOffSaysItDoesNotAnswer() async {
        let cloud = FakeBrainRoute(config: ["enabled": false, "model": "claude-opus-5-5", "effort": "low"])
        let view = Self.card(cloud)
        await view.use(Self.engine(cloud)).value
        #expect(!view.failure.isHidden)
        #expect(view.failure.stringValue == HomeEngineStrings.hostedBrainOff)
        // Its settings still show and can be changed.
        #expect(view.model.isEnabled)
    }

    // MARK: Helpers

    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    static func home() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hosted-chief-\(UUID().uuidString)", isDirectory: true)
    }

    static func engine(_ cloud: FakeBrainRoute) -> HomeChiefHostedEngine {
        HomeChiefHostedEngine(chief: { agent }, send: { method, path, body in try await cloud.answer(method, path, body) },
                              files: HomeChiefFiles(muxHome: home()))
    }

    /// A card that starts on a source that never answers, as the app's does before `use`.
    static func card(_ cloud: FakeBrainRoute) -> HomeChiefSettingsView {
        HomeChiefSettingsView(muxHome: home(), source: engine(cloud))
    }
}

/// The Cloud service's brain route as chief-brain/routes.ts answers it: GET is
/// `{ok, value: {config, turns_today}}`, PUT applies the patch and answers `{ok, value: config}`.
@MainActor
final class FakeBrainRoute {
    struct Request {
        var method: String
        var path: String
        var body: [String: String]?
    }

    var config: [String: Any]
    var requests: [Request] = []
    /// Every PUT is refused with this status, code and message.
    var refusal: (status: Int, code: String, message: String)?
    /// Every request throws this before it is sent.
    var failure: (any Error)?

    init(config: [String: Any]) {
        self.config = config
    }

    func answer(_ method: String, _ path: String, _ body: Data?) async throws -> (status: Int, body: Data) {
        if let failure { throw failure }
        let patch = body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: String] }
        requests.append(Request(method: method, path: path, body: patch))
        if method == "PUT" {
            if let refusal {
                return (refusal.status, try JSONSerialization.data(withJSONObject: ["ok": false, "error": ["code": refusal.code, "message": refusal.message]]))
            }
            for (key, value) in patch ?? [:] { config[key] = value }
            return (200, try JSONSerialization.data(withJSONObject: ["ok": true, "value": config]))
        }
        return (200, try JSONSerialization.data(withJSONObject: ["ok": true, "value": ["config": config, "turns_today": 0]]))
    }
}
