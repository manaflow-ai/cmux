import Foundation
import Testing
@testable import CmuxHomeCore

/// The Hosted Chief check Home runs so a Chief that does not answer is never
/// silent: which Chief it reads, which card a read or a Turn On leaves, the
/// model over the mock owner, and the cloud wire calls.
@MainActor @Suite struct HomeChiefBrainTests {
    nonisolated static let hosted = "agent_01HZZZZZZZZZZZZZZZZZZZZZZZ"
    nonisolated static let other = "agent_01HYYYYYYYYYYYYYYYYYYYYYYY"

    private func entry(_ id: String, isDefault: Bool = false, placed: Bool = false, main: String? = "conv_dm_1") -> HomeCloudChiefEntry {
        HomeCloudChiefEntry(id: id, isDefault: isDefault, isPlaced: placed, mainConversation: main)
    }

    // MARK: Which Chief

    @Test func picksTheDefaultHostedChief() {
        let chiefs = [entry(Self.other), entry(Self.hosted, isDefault: true)]
        #expect(HomeCloudChiefEntry.hostedChief(in: chiefs)?.id == Self.hosted)
    }

    @Test func withoutADefaultPicksTheFirstHostedChief() {
        let chiefs = [entry(Self.other, placed: true), entry(Self.hosted), entry(Self.other)]
        #expect(HomeCloudChiefEntry.hostedChief(in: chiefs)?.id == Self.hosted)
    }

    @Test func aPlacedDefaultChiefIsNotTheCloudBrainsToReport() {
        let chiefs = [entry(Self.other, isDefault: true, placed: true), entry(Self.hosted)]
        #expect(HomeCloudChiefEntry.hostedChief(in: chiefs) == nil)
    }

    @Test func skipsChiefsWithoutAConversationOrAValidID() {
        #expect(HomeCloudChiefEntry.hostedChief(in: []) == nil)
        #expect(HomeCloudChiefEntry.hostedChief(in: [entry(Self.hosted, isDefault: true, main: nil)]) == nil)
        #expect(HomeCloudChiefEntry.hostedChief(in: [entry("agent_../../v1/ops", isDefault: true)]) == nil)
        #expect(HomeCloudChiefEntry.isAgentID(Self.hosted))
        #expect(!HomeCloudChiefEntry.isAgentID("agent_01HZZZZZZZZZZZZZZZZZZZZZZO"))
        #expect(!HomeCloudChiefEntry.isAgentID("agent_01HZZZ"))
    }

    // MARK: Which card

    @Test func aReadShowsTheCardOnlyWhileTheBrainIsOff() {
        let off = HomeChiefBrainReading(chief: Self.hosted, enabled: false)
        let on = HomeChiefBrainReading(chief: Self.hosted, enabled: true)
        #expect(HomeChiefBanner.after(read: .success(off), current: nil) == .off)
        #expect(HomeChiefBanner.after(read: .success(on), current: .off) == nil)
        #expect(HomeChiefBanner.after(read: .success(on), current: .failed) == nil)
        // No Hosted Chief brain here (self-hosted, brains off): nothing to say.
        #expect(HomeChiefBanner.after(read: .success(nil), current: .off) == nil)
    }

    @Test func aReadKeepsAFailedTurnOnAndOneInFlight() {
        let off = HomeChiefBrainReading(chief: Self.hosted, enabled: false)
        #expect(HomeChiefBanner.after(read: .success(off), current: .failed) == .failed)
        #expect(HomeChiefBanner.after(read: .success(nil), current: .turningOn) == .turningOn)
    }

    @Test func aFailedReadNeitherInventsNorDropsACard() {
        let failure: Result<HomeChiefBrainReading?, any Error> = .failure(HomeRejection.ownerUnreachable)
        #expect(HomeChiefBanner.after(read: failure, current: nil) == nil)
        #expect(HomeChiefBanner.after(read: failure, current: .off) == .off)
    }

    @Test func aTurnOnAnswerClearsFailsOrSaysTheAccountCannotRunIt() {
        #expect(HomeChiefBanner.after(turnOn: nil) == nil)
        #expect(HomeChiefBanner.after(turnOn: HomeRejection.ownerUnreachable) == .failed)
        #expect(HomeChiefBanner.after(turnOn: HomeRejection.indeterminate) == .failed)
        #expect(HomeChiefBanner.after(turnOn: HomeRejection.invalid("validation.invalid")) == .failed)
        #expect(HomeChiefBanner.after(turnOn: HomeRejection.invalid("chief_claude_unavailable")) == .unavailable)
        #expect(HomeChiefBanner.after(turnOn: HomeRejection.invalid("chief_model_unavailable")) == .unavailable)
    }

    @Test func aReadWhileStillOffKeepsUnavailableAndAReadWhileOnClearsIt() {
        let off = HomeChiefBrainReading(chief: Self.hosted, enabled: false)
        let on = HomeChiefBrainReading(chief: Self.hosted, enabled: true)
        #expect(HomeChiefBanner.after(read: .success(off), current: .unavailable) == .unavailable)
        #expect(HomeChiefBanner.after(read: .success(on), current: .unavailable) == nil)
    }

    // MARK: The model over the mock owner

    @Test func turnOnTurnsTheBrainOnAndClearsTheCard() async throws {
        let mock = MockHomeSource(options: .immediate)
        await mock.setHostedChiefBrain(enabled: false)
        let model = HomeChiefBrainModel(control: mock)
        await model.refresh()
        #expect(model.banner == .off)
        await model.turnOn()
        #expect(model.banner == nil)
        #expect(try await mock.chiefBrain()?.enabled == true)
        await model.refresh()
        #expect(model.banner == nil)
    }

    @Test func aFailedTurnOnSaysSoAndTryAgainRetries() async throws {
        let mock = MockHomeSource(options: .immediate)
        await mock.setHostedChiefBrain(enabled: false, failingTurnOns: 1)
        let model = HomeChiefBrainModel(control: mock)
        await model.refresh()
        await model.turnOn()
        #expect(model.banner == .failed)
        // A read while it is still off keeps Try Again, not a fresh Turn On.
        await model.refresh()
        #expect(model.banner == .failed)
        await model.turnOn()
        #expect(model.banner == nil)
    }

    @Test func anAccountThatMayNotRunTheModelGetsNoRetry() async throws {
        let http = FakeWireHTTP { path, body in
            if path == "/v1/read", body["op"].string == "chief.list" { return Self.chiefList() }
            if path == "/v1/chiefs/\(Self.hosted)/brain" {
                if body["enabled"].bool == true {
                    return HomeWireHTTPReply(status: 409, json: ["ok": false, "error": ["code": "chief_claude_unavailable",
                                                                                         "message": "claude-opus-5-5 is not available for this account here"]])
                }
                return HomeWireHTTPReply(json: ["ok": true, "value": ["config": ["enabled": false]]])
            }
            return nil
        }
        let model = HomeChiefBrainModel(control: cloudSource(http))
        await model.refresh()
        #expect(model.banner == .off)
        await model.turnOn()
        #expect(model.banner == .unavailable)
        // No Turn On is offered, and none is sent.
        await model.turnOn()
        #expect(http.requests.filter { $0.httpMethod == "PUT" }.count == 1)
        await model.refresh()
        #expect(model.banner == .unavailable)
    }

    @Test func aReadNeverTurnsTheBrainOn() async throws {
        let mock = MockHomeSource(options: .immediate)
        await mock.setHostedChiefBrain(enabled: false)
        let model = HomeChiefBrainModel(control: mock)
        await model.refresh()
        await model.refresh()
        #expect(try await mock.chiefBrain()?.enabled == false)
    }

    @Test func noHostedChiefBrainShowsNothingAndTurnOnDoesNothing() async throws {
        let mock = MockHomeSource(options: .immediate)
        let model = HomeChiefBrainModel(control: mock)
        await model.refresh()
        #expect(model.banner == nil)
        await model.turnOn()
        #expect(model.banner == nil)
    }

    // MARK: The cloud wire

    private func cloudSource(_ http: FakeWireHTTP, auth: HomeWireAuth = .stack(FakeBearer())) -> WireHomeSource {
        WireHomeSource(baseURL: URL(string: "https://cloud-api.example.test")!, auth: auth, displayName: "Me",
                       http: http, sockets: FakeWireSockets(), clock: ManualClock(),
                       fetchDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("chief-brain-\(UUID().uuidString)"))
    }

    nonisolated private static func chiefList() -> HomeWireHTTPReply {
        HomeWireHTTPReply(json: ["ok": true, "value": ["chiefs": [
            ["id": .string(other), "rev": 1, "is_default": false, "main_conversation": "conv_dm_2",
             "brain_place": ["host": "mini", "install": "inst_1"]],
            ["id": .string(hosted), "rev": 2, "is_default": true, "main_conversation": "conv_dm_1"],
        ]]])
    }

    @Test func readsTheHostedChiefsBrainFromTheCloud() async throws {
        let http = FakeWireHTTP { path, body in
            if path == "/v1/read", body["op"].string == "chief.list" { return Self.chiefList() }
            if path == "/v1/chiefs/\(Self.hosted)/brain" {
                return HomeWireHTTPReply(json: ["ok": true, "value": ["config": ["enabled": false, "model": "claude-opus-5-5"], "turns_today": 0]])
            }
            return nil
        }
        let reading = try await cloudSource(http).chiefBrain()
        #expect(reading == HomeChiefBrainReading(chief: Self.hosted, enabled: false))
        let brainRequests = http.requests.filter { $0.url?.path == "/v1/chiefs/\(Self.hosted)/brain" }
        #expect(brainRequests.map(\.httpMethod) == ["GET"])
    }

    @Test func aDeploymentWithBrainsOffReadsAsNothingToCheck() async throws {
        let http = FakeWireHTTP { path, body in
            if path == "/v1/read", body["op"].string == "chief.list" { return Self.chiefList() }
            return nil // the brain route falls through to the fake's 404
        }
        #expect(try await cloudSource(http).chiefBrain() == nil)
    }

    @Test func aSelfHostedServerIsNeverAsked() async throws {
        let http = FakeWireHTTP()
        #expect(try await cloudSource(http, auth: .tailscale).chiefBrain() == nil)
        #expect(http.requests.isEmpty)
    }

    @Test func aRefusedReadThrows() async throws {
        let http = FakeWireHTTP { path, body in
            if path == "/v1/read", body["op"].string == "chief.list" { return Self.chiefList() }
            if path.hasSuffix("/brain") { return HomeWireHTTPReply(status: 503, json: ["ok": false]) }
            return nil
        }
        let source = cloudSource(http)
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.chiefBrain() }
    }

    @Test func turnOnSendsOnlyEnabled() async throws {
        let http = FakeWireHTTP { path, _ in
            path.hasSuffix("/brain") ? HomeWireHTTPReply(json: ["ok": true, "value": ["enabled": true]]) : nil
        }
        try await cloudSource(http).setChiefBrain(Self.hosted, enabled: true)
        let put = try #require(http.requests.first { $0.url?.path == "/v1/chiefs/\(Self.hosted)/brain" })
        #expect(put.httpMethod == "PUT")
        #expect(HomeWireJSON.parse(put.httpBody ?? Data()) == ["enabled": true])
        #expect(put.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
    }

    @Test func turnOnRefusesAnIDThatIsNotAChief() async throws {
        let http = FakeWireHTTP()
        let source = cloudSource(http)
        await #expect(throws: HomeRejection.invalid("chief.invalid")) {
            try await source.setChiefBrain("agent_../ops", enabled: true)
        }
        #expect(http.requests.isEmpty)
    }
}
