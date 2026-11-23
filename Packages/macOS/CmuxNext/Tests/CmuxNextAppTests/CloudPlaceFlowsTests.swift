import Foundation
@testable import CmuxNextCloudPlace
import Testing

/// The move's flow reports each step to Rust's reducer in order, and Cancel stops the move's Task only when the reducer says stop.
@MainActor struct CloudPlaceFlowsTests {
    /// A fake reducer: records each event's name, answers `stop` for a cancel when told to.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        var stopOnCancel = true
        var events: [String] { lock.withLock { names } }

        func core(_ operation: String, _ request: Data) -> Data? {
            guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any] else { return nil }
            if operation == "cloud_move_place_view" { return Data(#"{"state":"moving"}"#.utf8) }
            let event = (object["event"] as? [String: Any])?["event"] as? String ?? ""
            lock.withLock { names.append(event) }
            let next = event == "cancel" && stopOnCancel ? "stop" : "go"
            return Data(#"{"flow":{"n":1},"next":"\#(next)"}"#.utf8)
        }
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

    @Test func modesPersist() {
        let defaults = UserDefaults(suiteName: "CloudPlaceFlowsTests.\(UUID().uuidString)")!
        let first = CloudPlaceFlows(defaults: defaults)
        first.setMode("auto", of: "s")
        #expect(CloudPlaceFlows(defaults: defaults).mode(of: "s") == "auto")
    }
}
