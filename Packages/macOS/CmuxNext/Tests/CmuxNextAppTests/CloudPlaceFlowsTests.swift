import Foundation
@testable import CmuxNextCloudPlace
import Testing

/// The move's flow reports each step to Rust's reducer in order, and Cancel stops the move's Task only when the reducer says stop.
@MainActor struct CloudPlaceFlowsTests {
    /// A fake reducer: records each event's name, answers `stop` for a cancel when told to.
    nonisolated final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        var stopOnCancel = true
        var events: [String] { lock.withLock { names } }

        func core(_ operation: String, _ request: Data) -> Data? {
            guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any] else { return nil }
            if operation == "cloud_move_place_view" { return Data((events.last == "failed" ? #"{"state":"failed"}"# : #"{"state":"moving"}"#).utf8) }
            let event = (object["event"] as? [String: Any])?["event"] as? String ?? ""
            lock.withLock { names.append(event) }
            let next = event == "cancel" && stopOnCancel ? "stop" : "go"
            return Data(#"{"flow":{"n":1},"next":"\#(next)"}"#.utf8)
        }
    }

    /// A fake app: one chat on this Mac, and how it answers a move (refused at once, or started).
    @MainActor final class Host: CloudPlaceHost {
        var chats = [CloudPlaceChat(id: "tab", session: "s", onCloud: false, turnRunning: false, turnStartedAtMs: nil, moving: false)]
        var refusal: String?
        var runs = 0
        func placeChats() -> [CloudPlaceChat] { chats }
        func placeRun(_ chat: CloudPlaceChat, toCloud: Bool, machine: CloudPlaceMachine?, trigger: CloudPlaceFlows.Trigger, claims: CloudPlaceClaims) -> CloudPlaceRun {
            runs += 1
            if let refusal { return .refused(refusal) }
            return .started({})
        }
        func placeCloudSessions() -> [String] { [] }
        func placeOwnFacts(_ session: String) -> (before: String?, machines: [CloudPlaceOwnMachine]) { (nil, []) }
        func placeOnTurnEnded(_ handler: @escaping @MainActor (String) -> Void) {}
    }

    private func flows(_ recorder: Recorder) -> CloudPlaceFlows {
        let defaults = UserDefaults(suiteName: "CloudPlaceFlowsTests.\(UUID().uuidString)")!
        return CloudPlaceFlows(defaults: defaults, core: { recorder.core($0, $1) }, clock: { 1 })
    }

    @Test func reportsEveryStepInOrder() throws {
        let recorder = Recorder()
        let place = flows(recorder)
        place.begin(session: "s", toCloud: true, trigger: .person, from: "Mac", to: "", cargo: .init())
        try place.advance("s", "machine")
        place.target("s", to: "vm")
        try place.advance("s", "sync")
        try place.advance("s", "freeze")
        place.step("s", "commit")
        place.step("s", "attach")
        place.step("s", "release")
        place.live("s")
        #expect(recorder.events == ["begin", "step", "target", "step", "step", "step", "step", "step", "live"])
        #expect(place.state(of: "s") == "moving")
        #expect(place.placeJSON(session: "s", onCloud: true, cloudName: "vm") != nil)
    }

    @Test func cancelStopsTheTaskOnlyOnStop() throws {
        let recorder = Recorder()
        let place = flows(recorder)
        var stopped = 0
        place.begin(session: "s", toCloud: true, trigger: .evacuate, from: "Mac", to: "", cargo: .init())
        place.onCancel("s") { stopped += 1 }
        #expect(place.cancel("s") == .stop)
        #expect(stopped == 1)
        #expect(place.wasCancelled("s"))
        recorder.stopOnCancel = false
        place.begin(session: "t", toCloud: true, trigger: .person, from: "Mac", to: "", cargo: .init())
        place.onCancel("t") { stopped += 1 }
        #expect(place.cancel("t") == .go)
        #expect(stopped == 1)
    }

    /// A move the app refuses at once (no first message, no chat there) fails in the chat's flow, so the chat shows why and
    /// Retry, and the page's action answers with the reason; never the asked mode with nothing moving (review of #52230, F1).
    @Test func aMoveRefusedAtOnceFailsInTheChatsFlowAndAnswersWhy() {
        let recorder = Recorder(), host = Host()
        let place = flows(recorder)
        let driver = CloudPlaceDriver(place: place, host: host)
        host.refusal = "Send a first message, then move this chat."
        #expect(driver.setMode("cloud", tab: nil, session: "s") == .refused("Send a first message, then move this chat."))
        #expect(recorder.events == ["begin", "failed"])
        #expect(place.state(of: "s") == "failed")
        #expect(place.mode(of: "s") == "cloud")
        #expect(driver.retry(tab: nil, session: "s") == .refused("Send a first message, then move this chat."))
        host.refusal = nil
        #expect(driver.retry(tab: nil, session: "s") == nil)
        #expect(host.runs == 3)
    }

    @Test func modesPersist() {
        let defaults = UserDefaults(suiteName: "CloudPlaceFlowsTests.\(UUID().uuidString)")!
        let first = CloudPlaceFlows(defaults: defaults)
        first.setMode("auto", of: "s")
        #expect(CloudPlaceFlows(defaults: defaults).mode(of: "s") == "auto")
    }

    @Test func dirtyCountSkipsARenamesSourcePath() {
        let out = Data(" M a.txt\0R  new.txt\0old.txt\0?? b.txt\0".utf8)
        #expect(CloudPlaceFlows.dirtyCount(porcelainZ: out) == 3)
        #expect(CloudPlaceFlows.dirtyCount(porcelainZ: Data()) == 0)
    }

    @Test func evacuationShowsEachChatsStateAndCancelDropsTheQueue() throws {
        let place = flows(Recorder())
        place.beginEvacuation(direction: "toCloud", chats: [("a", "A"), ("b", "B"), ("c", "C")])
        place.evacuationPhase("a", .running)
        place.evacuationPhase("b", .running)
        place.evacuationPhase("b", .ended) // no flow was kept: read as failed, never as landed
        #expect(place.stopEvacuation() == ["a"])
        #expect(place.evacuationStopped)
        let object = try #require(place.evacuateJSON(canBringBack: 2).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let states = (object["chats"] as? [[String: Any]])?.map { $0["state"] as? String }
        #expect(states == ["moving", "failed", "cancelled"])
        #expect(object["direction"] as? String == "toCloud" && object["canBringBack"] as? Int == 2 && object["elapsedMs"] != nil)
        place.evacuationPhase("a", .ended)
        #expect(place.evacuation?.endedMs != nil)
    }

    @Test func idleEvacuateCarriesOnlyTheBringBackCount() throws {
        let place = flows(Recorder())
        #expect(place.evacuateJSON(canBringBack: 0) == nil)
        let object = try #require(place.evacuateJSON(canBringBack: 3).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Set(object.keys) == ["canBringBack"])
    }
}
