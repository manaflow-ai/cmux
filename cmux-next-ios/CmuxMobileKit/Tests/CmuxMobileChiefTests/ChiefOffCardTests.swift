import Foundation
import Testing
@testable import CmuxMobileChief

/// The App Review path with no Mac: every new account's Hosted Chief has its
/// brain off, so Home must say so and offer Turn On, and the service alone
/// decides whether this account may (no account is named in the app). Which
/// card Home shows, and what a Turn On's answer leaves on it.
@MainActor
@Suite(.serialized) struct ChiefOffCardTests {
    static let hosted = "agent_01HZZZZZZZZZZZZZZZZZZZZZZZ"
    static let other = "agent_01HYYYYYYYYYYYYYYYYYYYYYYY"

    // MARK: Which card

    @Test func noCardUnlessTheBrainIsOff() {
        #expect(ChiefOffCard.decide(offChief: nil, turningOn: nil, refusal: nil) == nil)
        #expect(ChiefOffCard.decide(offChief: nil, turningOn: Self.hosted,
                                    refusal: .init(chief: Self.hosted, kind: .unavailable)) == nil)
        #expect(ChiefOffCard.decide(offChief: Self.hosted, turningOn: nil, refusal: nil) == .off)
    }

    @Test func aTurnOnInFlightShowsAsTurningOn() {
        #expect(ChiefOffCard.decide(offChief: Self.hosted, turningOn: Self.hosted, refusal: nil) == .turningOn)
        // Even over the last refusal: the new tap's answer decides.
        #expect(ChiefOffCard.decide(offChief: Self.hosted, turningOn: Self.hosted,
                                    refusal: .init(chief: Self.hosted, kind: .retryable)) == .turningOn)
        // A Turn On for another chief is not this card's.
        #expect(ChiefOffCard.decide(offChief: Self.hosted, turningOn: Self.other, refusal: nil) == .off)
    }

    @Test func aRefusalShowsAsFailedOrUnavailableForItsOwnChiefOnly() {
        #expect(ChiefOffCard.decide(offChief: Self.hosted, turningOn: nil,
                                    refusal: .init(chief: Self.hosted, kind: .retryable)) == .failed)
        #expect(ChiefOffCard.decide(offChief: Self.hosted, turningOn: nil,
                                    refusal: .init(chief: Self.hosted, kind: .unavailable)) == .unavailable)
        #expect(ChiefOffCard.decide(offChief: Self.hosted, turningOn: nil,
                                    refusal: .init(chief: Self.other, kind: .unavailable)) == .off)
    }

    @Test func onlyOffAndFailedTakeATap() {
        #expect(ChiefOffCard.off.offersTurnOn)
        #expect(ChiefOffCard.failed.offersTurnOn)
        #expect(!ChiefOffCard.turningOn.offersTurnOn)
        #expect(!ChiefOffCard.unavailable.offersTurnOn)
    }

    @Test func theServicesOwnerListRefusalsAreUnavailableAndTheRestRetryable() {
        func kind(_ error: any Error) -> ChiefOffCard.Refusal.Kind { ChiefOffCard.refusal(of: Self.hosted, for: error).kind }
        #expect(kind(ChiefCloudError.refused(status: 403, code: "chief_claude_unavailable", message: "x")) == .unavailable)
        #expect(kind(ChiefCloudError.refused(status: 403, code: "chief_model_unavailable", message: "x")) == .unavailable)
        #expect(kind(ChiefCloudError.refused(status: 500, code: "http_500", message: "HTTP 500")) == .retryable)
        #expect(kind(ChiefCloudError.refused(status: 400, code: "validation.invalid", message: "x")) == .retryable)
        #expect(kind(ChiefCloudError.badReply("x")) == .retryable)
        #expect(kind(URLError(.notConnectedToInternet)) == .retryable)
        #expect(ChiefOffCard.refusal(of: Self.hosted, for: URLError(.timedOut)).chief == Self.hosted)
    }

    // MARK: Turn On over the service

    final class Service: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var answer: (status: Int, body: String) = (200, "{}")
        nonisolated(unsafe) static var seen: [(method: String, path: String, body: [String: Any])] = []
        static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let data = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let answer = Self.lock.withLock {
                Self.seen.append((request.httpMethod ?? "", request.url?.path ?? "", object))
                return Self.answer
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, // crash-allow: test stub
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        static func read(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }

        static func reset(_ status: Int, _ body: String) {
            lock.withLock {
                answer = (status, body)
                seen = []
            }
        }
    }

    /// Sources whose Cloud Chief `hosted` was read with its brain off (no account
    /// id, so a successful Turn On's follow-up read does not run).
    private func sourcesWithTheBrainOff() -> (ChiefSources, CloudChief) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Service.self]
        let mac = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil), clock: ImmediateClock())
        let cloud = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil), clock: ImmediateClock())
        let sources = ChiefSources(mac: mac, cloud: cloud,
                                   selection: UserDefaults(suiteName: "ChiefOffCardTests.\(UUID().uuidString)") ?? .standard)
        sources.http = ChiefCloudHTTP(base: URL(string: "https://cloud-api-staging.cmux.dev")!, // crash-allow: test literal
                                      accessToken: { _ in "token" }, session: URLSession(configuration: configuration))
        let chief = CloudChief(id: Self.hosted, displayName: "Chief", isDefault: true, mainConversation: "conv_dm_1", rev: 1, brainPlace: nil)
        sources.cloudState = .unavailable("Cloud Chief is turned off.", .turnOn(chief))
        return (sources, chief)
    }

    @Test func turnOnSendsOnlyThePersonsTapAndClearsTheCard() async {
        Service.reset(200, #"{"ok":true,"value":{"config":{"enabled":true}}}"#)
        let (sources, chief) = sourcesWithTheBrainOff()
        #expect(sources.offCard == .off)
        await sources.turnOn(chief)
        let sent = Service.lock.withLock { Service.seen }
        #expect(sent.count == 1)
        #expect(sent.first?.method == "PUT")
        #expect(sent.first?.path == "/v1/chiefs/\(Self.hosted)/brain")
        #expect(sent.first?.body["enabled"] as? Bool == true)
        #expect(sources.turnOnRefusal == nil)
        #expect(!sources.isChanging)
        #expect(sources.changeError == nil)
        // The spinner stays until the follow-up read lands, so Turn On never flashes back.
        #expect(sources.offCard == .turningOn)
    }

    @Test func anAccountTheServiceRefusesShowsUnavailableWithNoButtonUntilTheAppComesBack() async {
        Service.reset(403, #"{"error":{"code":"chief_claude_unavailable","message":"Claude is not enabled for this owner"}}"#)
        let (sources, chief) = sourcesWithTheBrainOff()
        await sources.turnOn(chief)
        #expect(sources.offCard == .unavailable)
        #expect(sources.offCard?.offersTurnOn == false)
        // The card says it, not the red change error under Home.
        #expect(sources.changeError == nil)
        // Back from the background (the operator may have added the account): Turn On again.
        sources.wake()
        #expect(sources.offCard == .off)
    }

    @Test func aFailedTurnOnOffersTryAgainAndASuccessClearsIt() async {
        Service.reset(503, #"{}"#)
        let (sources, chief) = sourcesWithTheBrainOff()
        await sources.turnOn(chief)
        #expect(sources.offCard == .failed)
        #expect(sources.offCard?.offersTurnOn == true)
        Service.reset(200, #"{"ok":true,"value":{"config":{"enabled":true}}}"#)
        await sources.turnOn(chief)
        #expect(sources.turnOnRefusal == nil)
        #expect(sources.offCard == .turningOn) // until the follow-up read says the brain is on
    }

    @Test func signingOutForgetsTheRefusal() async {
        Service.reset(403, #"{"error":{"code":"chief_claude_unavailable","message":"no"}}"#)
        let (sources, chief) = sourcesWithTheBrainOff()
        await sources.turnOn(chief)
        #expect(sources.turnOnRefusal != nil)
        sources.stop()
        #expect(sources.turnOnRefusal == nil)
        #expect(sources.offCard == nil)
    }
}
