import CmuxSafeConcurrency
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// A renderer stability report is one warning event with closed-set `stability.*` tags, its
/// count (and span) in `extra`, and a fingerprint of its names; it carries no URL, title or host, even when a caller
/// plants one in a field. It is built and sent on the reporter's lane, and nothing is sent with crash reporting off.
struct RendererStabilityEventTests {
    private static let planted = "https://planted.example/account?token=s3cr3t#title"

    /// The serialized event, as Sentry would send it.
    private static func json(_ event: Event) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: event.serialize(), options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func aContentEndIsOneWarningGroupedByItsNames() throws {
        let event = RendererStabilityEvent(kind: "content_ended", engine: "webkit", surface: "browser_tab", count: 3).event()
        #expect(event.level == .warning)
        #expect(event.tags == ["stability.kind": "content_ended", "stability.engine": "webkit", "stability.surface": "browser_tab"])
        #expect(event.extra?["stability_count"] as? Int == 3)
        #expect(event.extra?["unresponsive_ms"] == nil)
        #expect(event.fingerprint == ["renderer_stability", "content_ended", "webkit", "browser_tab"])
        #expect(event.exceptions == nil, "the renderer is another process: no app stack")
    }

    @Test func aHangCarriesItsLengthAndHowItEnded() {
        let event = RendererStabilityEvent(kind: "unresponsive", engine: "chromium", surface: "page", count: 1,
                                           unresponsiveMilliseconds: 4_250, ending: "process_ended").event()
        #expect(event.tags?["stability.ending"] == "process_ended")
        #expect(event.extra?["unresponsive_ms"] as? Int64 == 4_250)
        #expect(event.fingerprint == ["renderer_stability", "unresponsive", "chromium", "page"])
    }

    /// The scrubber test: a URL planted in every free field never reaches the serialized event.
    @Test func aPlantedURLNeverReachesTheEvent() throws {
        let event = RendererStabilityEvent(kind: Self.planted, engine: Self.planted, surface: Self.planted, count: 1,
                                           unresponsiveMilliseconds: 10, ending: Self.planted).event()
        let json = try Self.json(event)
        #expect(!json.contains("planted.example"))
        #expect(!json.contains("://"))
        #expect(!json.contains("s3cr3t"))
        #expect(event.tags?.values.allSatisfy { $0 == "other" } == true)
        #expect(event.fingerprint == ["renderer_stability", "other", "other", "other"])
    }

    @Test(arguments: ["content_ended", "browser_tab", "webkit", "process_ended"])
    func closedSetNamesPassUnchanged(name: String) {
        #expect(RendererStabilityEvent.name(name) == name)
    }

    @Test(arguments: ["", "Page", "page-1", "page.html", String(repeating: "a", count: 33), "é"])
    func anythingElseIsOther(value: String) {
        #expect(RendererStabilityEvent.name(value) == "other")
    }

    @Test(arguments: [false, true])
    func theReporterSendsOnItsLaneOnlyWhileReportingRuns(reporting: Bool) {
        let lane = StabilityLane()
        let reporter = RendererStabilityReporter(sends: { reporting }, lane: lane.lane, capture: lane.capture)
        reporter.send(RendererStabilityEvent(kind: "content_ended", engine: "webkit", surface: "page", count: 2))
        #expect(lane.surfaces.isEmpty, "nothing is built or sent on the caller's thread")
        #expect(lane.held == (reporting ? 1 : 0), "only while reporting runs is a block enqueued")
        lane.runHeld()
        #expect(lane.surfaces == (reporting ? ["page"] : []))
    }
}

/// Blocks a reporter's lane was given, held until the test runs them, and the surface tag of each event captured.
private final class StabilityLane: Sendable {
    private let blocks = CmuxSafeConcurrency.Mutex<[@Sendable () -> Void]>([])
    private let sent = CmuxSafeConcurrency.Mutex<[String?]>([])

    var lane: RendererStabilityReporter.Lane {
        { block in self.blocks.withLock { $0.append(block) } }
    }

    var capture: RendererStabilityReporter.Capture {
        { event in
            let surface = event.tags?["stability.surface"]
            self.sent.withLock { $0.append(surface) }
        }
    }

    var held: Int { blocks.withLock { $0.count } }
    var surfaces: [String?] { sent.withLock { $0 } }

    func runHeld() {
        let run = blocks.withLock { blocks in
            let run = blocks
            blocks = []
            return run
        }
        for block in run { block() }
    }
}
