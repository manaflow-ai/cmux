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

    /// A new Chief is in the directory's `chief.list` before the Chief tab lists it: its
    /// `brain_place` there still decides hosted or placed.
    @Test func theDirectoryListDecidesWhileTheChiefTabDoesNotKnowTheChief() {
        let list: [String: Any] = ["chiefs": [
            ["id": Self.agent, "display_name": "New", "rev": 1, "main_conversation": Self.main],
            ["id": "agent_placed", "display_name": "Mini", "rev": 2, "main_conversation": "conv_placed",
             "brain_place": ["host": "host_mini", "install": "install_1"]],
            ["id": "agent_old", "rev": 3, "main_conversation": "conv_old", "archived_at": "2026-10-01T00:00:00Z"],
        ]]
        let records = HomeChiefRecord.list(from: list)
        #expect(records.map(\.id) == [Self.agent, "agent_placed"])
        #expect(HomeChiefRecord.archivedIDs(from: list) == ["agent_old"])
        // A deleted Chief (and one archived past its restore window) is only a tombstone: still hidden.
        var deleted = list
        deleted["tombstones"] = [["id": "agent_gone", "owner_user": "user_1", "archived_at": "2026-10-02T00:00:00Z"]]
        #expect(HomeChiefRecord.archivedIDs(from: deleted) == ["agent_old", "agent_gone"])
        let none = HomeCloudChiefs()
        #expect(none.placement(of: Self.main, records: records).map { [$0.id, "\($0.placed)"] } == [Self.agent, "false"])
        #expect(none.placement(of: "conv_placed", records: records)?.placed == true)
        #expect(none.placement(of: "conv_unknown", records: records) == nil)
    }

    @Test func thisMacsChiefStaysLocal() {
        let services = Self.services()
        let control = HomeChiefControl(services: services, conversation: ConversationID("conv_local"), muxHome: Self.home())
        #expect(!control.isHosted)
        #expect(control.engineSource() is HomeChiefLocalEngine)
    }

    // MARK: This Mac's Chief beside the cloud Chiefs

    /// Leo 2026-10-21: this Mac's Chief's name-pill card said "Runs in the cloud" and "The server with
    /// this Chief is not connected." with empty pickers. With a hosted cloud Chief (and a placed one)
    /// in the cloud list, all named "Chief", this Mac's Chief, also "Chief" in the Home store, still
    /// talks to this Mac's brain: a classification by name would put it in the cloud.
    @Test func thisMacsChiefStaysLocalBesideAHostedCloudChief() async throws {
        let services = try await Self.servicesWithCloudChiefs()
        let control = HomeChiefControl(services: services, conversation: ConversationID(Self.local), muxHome: Self.home())
        #expect(!services.home.isCloudConversation(ConversationID(Self.local)))
        #expect(!control.isCloud)
        #expect(!control.isHosted)
        #expect(control.hostedChiefID == nil)
        #expect(control.server == nil)
        #expect(control.named == nil)
        #expect(control.brainHome == control.muxHome)
        #expect(control.engineSource() is HomeChiefLocalEngine)
        // Its card's place line is the engine's own ("Runs here"), with no switch to a cloud host.
        #expect(services.home.chiefHost(of: Self.local) == HomeChiefHostLine())
        // The cloud Chiefs keep their own brains.
        #expect(HomeChiefControl(services: services, conversation: ConversationID(Self.main), muxHome: Self.home()).engineSource()
            is HomeChiefHostedEngine)
        #expect(HomeChiefControl(services: services, conversation: ConversationID(Self.placedMain), muxHome: Self.home()).engineSource()
            is HomeChiefRemoteEngine)
    }

    /// A named local Chief (chief-brains-v1) beside the cloud Chiefs: its own brain on this Mac.
    @Test func aNamedLocalChiefStaysLocalBesideTheCloudChiefs() async throws {
        let services = try await Self.servicesWithCloudChiefs()
        var control = HomeChiefControl(services: services, conversation: ConversationID("conv_named"), muxHome: Self.home())
        control.chief = Self.namedChief
        #expect(!control.isCloud)
        #expect(control.named == control.chief)
        #expect(control.brainHome == ChiefHome.brainHome(muxHome: control.muxHome, chief: control.chief))
        let source = control.engineSource()
        #expect(source is HomeChiefLocalEngine)
        #expect((source as? HomeChiefLocalEngine)?.chief == control.chief)
        #expect(services.home.chiefHost(of: "conv_named") == HomeChiefHostLine())
    }

    /// The card the name pill opens over this Mac's Chief, as HomeHostView builds it: "Runs here",
    /// the Harness row, and the pickers filled from this Mac's engine.json, never the cloud's words.
    @Test func thisMacsChiefsCardRunsHereWithItsPickers() async throws {
        let services = try await Self.servicesWithCloudChiefs()
        let control = HomeChiefControl(services: services, conversation: ConversationID(Self.local), muxHome: Self.home())
        let engine = control.brainHome.appendingPathComponent("optchat/engine.json")
        try FileManager.default.createDirectory(at: engine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["harness": "codex", "model": "gpt-5.5", "effort": "high"]).write(to: engine)
        defer { try? FileManager.default.removeItem(at: control.muxHome) }

        let view = HomeChiefSettingsView(muxHome: control.brainHome, source: control.engineSource())
        let host = services.home.chiefHost(of: Self.local)
        view.setHost(place: host.place, switchTo: host.switchTo)
        await view.use(control.engineSource()).value
        #expect(view.place.stringValue == HomeEngineStrings.runsHere)
        #expect(view.hostSwitch.isHidden)
        #expect(view.failure.isHidden)
        #expect(view.harness.superview?.isHidden == false)
        #expect(view.harness.selectedItem?.representedObject as? String == "codex")
        #expect(view.model.selectedItem?.representedObject as? String == "gpt-5.5")
        #expect(view.effort.selectedItem?.representedObject as? String == "high")
        #expect(view.harness.isEnabled && view.model.isEnabled && view.effort.isEnabled)
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

    static let local = "conv_local"
    static let placedMain = "conv_dm_01JZ00000000000000000PLACED"

    static let namedChief = "agent_01JZ00000000000000000NAMED1"

    /// A signed-in Mac whose cloud list has a hosted Chief and one placed on a server, both "Chief",
    /// and whose Home store lists this Mac's Chief conversation (with agent_mux) and a named local
    /// Chief's as this Mac's owner reports them: owned here and titled "Chief" too.
    static func servicesWithCloudChiefs() async throws -> AppServices {
        // Its own Chief home, so the Home store's cache is this test's, never a real Chief's.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chief-local-\(UUID().uuidString)", isDirectory: true)
        let services = withChiefHome(root) {
            let made = Self.services()
            _ = made.home
            return made
        }
        let hosted = CloudChief(id: agent, displayName: "Chief", isDefault: true, mainConversation: main, rev: 1)
        let placed = CloudChief(id: "agent_01JZ00000000000000000PLACED", displayName: "Chief", isDefault: false,
                                mainConversation: placedMain, rev: 1, brainPlace: .init(host: "host_mini", install: "install_1"))
        services.home.setCloudChiefs(HomeCloudChiefs(hosted: hosted, placed: placed))

        let me = services.home.homeSource.me
        let date = Date(timeIntervalSince1970: 1_000)
        func chiefConversation(_ id: String, chief: String) -> CmuxHomeCore.ConversationSummary {
            let agent = Participant(id: ParticipantID(chief), kind: .agent, displayName: "Chief", agentClass: .chief)
            return CmuxHomeCore.ConversationSummary(id: ConversationID(id), owner: .local, title: "Chief", participants: [me, agent],
                                                    createdAt: date, updatedAt: date)
        }
        services.home.homeSource.publish(.inbox(InboxSnapshot(
            me: me, conversations: [chiefConversation(local, chief: "agent_mux"), chiefConversation("conv_named", chief: namedChief)], rev: 1)))
        let store = services.home.homeStore
        store.start()
        let listed = await eventually { store.summary(ConversationID(local)) != nil && store.summary(ConversationID("conv_named")) != nil }
        try #require(listed, "the Home store lists this Mac's Chiefs")
        #expect(store.summary(ConversationID(local))?.title == "Chief")
        #expect(store.summary(ConversationID(local))?.owner == .local)
        return services
    }

    /// Runs `body` with `CMUX_NEXT_CHIEF_HOME` at `root` (HomeService reads it when it is made).
    static func withChiefHome<T>(_ root: URL, _ body: () -> T) -> T {
        let key = "CMUX_NEXT_CHIEF_HOME"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, root.path, 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        return body()
    }

    static func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await clock.sleep(for: .milliseconds(10))
        }
        return condition()
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
