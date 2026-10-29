import CmuxNextControl
import CmuxNextInput
@testable import CmuxNextInputDiagnostics
import CmuxNextInputCore
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// `debug.input`: a read with every producer present decodes every section key into its
/// shape, a section without a producer is listed under `absent`, `reset` reaches every source and
/// recorder, a recorder that has not landed answers `unavailable`, the latency section is a real
/// `InputLatencyReporter`'s ledger, and the params parse strictly (a key the action does not take fails).
@MainActor @Suite
struct DebugInputTests {
    /// The names `reset` reached, in order.
    actor Resets {
        private(set) var names: [String] = []
        func note(_ name: String) { names.append(name) }
    }

    /// A section producer that returns a fixed value.
    nonisolated struct FixedSource<Value: Encodable & Sendable>: DebugInputSource {
        let section: DebugInputSection
        let value: Value
        let resets: Resets

        func read() async -> Value { value }
        func reset() async { await resets.note(section.rawValue) }
    }

    /// A recorder that returns fixed rows and the `since_launch` it was asked with.
    nonisolated struct FixedRecorder: DebugInputRecorder {
        nonisolated struct Rows: Encodable, Sendable {
            let sites: [String]
            let sinceLaunch: Bool

            enum CodingKeys: String, CodingKey {
                case sites
                case sinceLaunch = "since_launch"
            }
        }

        let kind: DebugInputRecorderKind
        let resets: Resets

        func rows(sinceLaunch: Bool) async -> Rows { Rows(sites: ["\(kind.rawValue).site"], sinceLaunch: sinceLaunch) }
        func reset() async { await resets.note(kind.rawValue) }
    }

    /// A section whose shape its own task owns (interactions, coalescer, scroll views, chromium).
    nonisolated struct Opaque: Codable, Sendable, Equatable {
        let count: Int
    }

    static let gate = DebugInputGate(heldByOrigin: .init(main: 3, offMain: 2), exemptByRule: ["input_dispatch": 5],
                                     maxInputWaitBehindJobsMilliseconds: 0.75, jobsDeferredOverOneFrame: 0,
                                     nonswiftBlocksWhileInputPending: 1)
    static let pump = DebugInputPump(passesWhileInputPending: ["terminal": 0, "chromiumPage": 4], deferredForInput: 9,
                                     passMillisecondsP99: 1.5)

    static let prewarm: DebugInputPrewarm = {
        var counters = IntentPrewarmCounters()
        counters.started = [.pointerDown: 3, .hoverDwell: 2]
        counters.hits = [.pointerDown: 2]
        counters.evicted = 1
        return DebugInputPrewarm(counters: counters, held: 2)
    }()

    static func latencyBatch() -> InputLatencyBatch {
        var slot = InputLatencySlot(kind: .keyPress, target: .terminal, entrypoint: .person, causedFrameUpdate: true)
        slot.generated = 1_000_000
        slot.presented = 7_000_000
        return InputLatencyBatch(slots: [slot], vsyncNanos: 16_666_667)
    }

    static func latency() -> InputLatencySnapshot {
        var ledger = InputLatencyLedger()
        ledger.fold(latencyBatch())
        return ledger.snapshot
    }

    /// A main-thread scheduler whose posted turns run as main-actor tasks: the tap section's copy is a posted task.
    static func mainWork() -> MainWorkScheduler {
        MainWorkScheduler.testing(ledger: WakeupLedger(), performTurn: { turn in Task { @MainActor in turn() } }) { _ in
            DebugInputTestLink()
        }
    }

    static func everySource(tap: InputEventTap, resets: Resets) -> [any DebugInputSource] {
        [
            FixedSource(section: .latency, value: latency(), resets: resets),
            FixedSource(section: .interactions, value: Opaque(count: 1), resets: resets),
            FixedSource(section: .gate, value: gate, resets: resets),
            FixedSource(section: .coalescer, value: Opaque(count: 2), resets: resets),
            InputTapDebugSource(tap: tap, mainWork: mainWork()),
            FixedSource(section: .pump, value: pump, resets: resets),
            FixedSource(section: .scrollViews, value: [Opaque(count: 3)], resets: resets),
            FixedSource(section: .chromium, value: Opaque(count: 4), resets: resets),
            FixedSource(section: .prewarm, value: prewarm, resets: resets),
        ]
    }

    /// The reply as Foundation JSON, the way a socket client reads it.
    static func object(_ value: JSONValue) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: value.foundationObject)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue?) throws -> T {
        let value = try #require(value)
        let data = try JSONSerialization.data(withJSONObject: value.foundationObject, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: read

    @Test func aReadWithEveryProducerDecodesEverySectionKey() async throws {
        let tap = InputEventTap()
        let keys = tap.subscribe(class: .key) { _ in }
        let scroll = tap.subscribe(class: .scroll, phase: .intercept(order: .layout)) { _ in .pass }
        tap.setFlag(.hintsShowing, true)
        let debugInput = DebugInput(sources: Self.everySource(tap: tap, resets: Resets()))

        let reply = try await debugInput.reply(to: DebugInput.Request(params: [:]))
        let object = try Self.object(reply)

        #expect(Set(object.keys) == Set(DebugInputSection.allCases.map(\.rawValue) + ["absent"]))
        #expect((object["absent"] as? [Any])?.isEmpty == true)
        #expect(try Self.decode(InputLatencySnapshot.self, reply["latency"]) == Self.latency())
        #expect(try Self.decode(DebugInputGate.self, reply["gate"]) == Self.gate)
        #expect(try Self.decode(DebugInputPump.self, reply["pump"]) == Self.pump)
        #expect(try Self.decode(Opaque.self, reply["interactions"]) == Opaque(count: 1))
        #expect(try Self.decode(Opaque.self, reply["coalescer"]) == Opaque(count: 2))
        #expect(try Self.decode([Opaque].self, reply["scroll_views"]) == [Opaque(count: 3)])
        #expect(try Self.decode(Opaque.self, reply["chromium"]) == Opaque(count: 4))
        #expect(try Self.decode(DebugInputPrewarm.self, reply["prewarm"]) == Self.prewarm)

        let tapSection = try Self.decode(DebugInputTap.self, reply["tap"])
        #expect(tapSection.subscribers.map(\.eventClass) == InputEventClass.allCases.map { String(describing: $0) })
        let keyRow = try #require(tapSection.subscribers.first { $0.eventClass == "key" })
        let scrollRow = try #require(tapSection.subscribers.first { $0.eventClass == "scroll" })
        #expect(keyRow == DebugInputTap.Subscribers(eventClass: "key", observe: 1, intercept: 0, afterDispatch: 0))
        #expect(scrollRow == DebugInputTap.Subscribers(eventClass: "scroll", observe: 0, intercept: 1, afterDispatch: 0))
        #expect(tapSection.flags == ["hints_showing"])
        #expect(tapSection.globalMonitors == 0)
        #expect(tapSection.lastDispatched == nil)
        withExtendedLifetime((keys, scroll)) {}
    }

    @Test func theSectionKeysAreTheSpecdNames() throws {
        #expect(DebugInputSection.allCases.map(\.rawValue)
            == ["latency", "interactions", "gate", "coalescer", "tap", "pump", "scroll_views", "chromium", "prewarm"])
        let gate = try Self.object(JSONValue.parse(JSONEncoder().encode(Self.gate)))
        #expect(Set(gate.keys) == ["held_by_origin", "exempt_by_rule", "max_input_wait_behind_jobs_ms",
                                   "jobs_deferred_over_one_frame", "nonswift_blocks_while_input_pending"])
        let held = try #require(gate["held_by_origin"] as? [String: Any])
        #expect(Set(held.keys) == ["main", "offMain"], "p04-input.md task 007 and DC10 name it offMain")
        let pump = try Self.object(JSONValue.parse(JSONEncoder().encode(Self.pump)))
        #expect(Set(pump.keys) == ["passes_while_input_pending", "deferred_for_input", "pass_ms_p99"])
        let prewarm = try Self.object(JSONValue.parse(JSONEncoder().encode(Self.prewarm)))
        #expect(Set(prewarm.keys) == ["started", "hits", "evicted", "cancelled_by_pressure", "skipped_for_power",
                                      "skipped_for_pressure", "held"])
        #expect(prewarm["started"] as? [String: Int] == ["pointerDown": 3, "hoverDwell": 2])
        let tap = try Self.object(JSONValue.parse(JSONEncoder().encode(InputTapDebugSource.snapshot(InputEventTap()))))
        #expect(Set(tap.keys) == ["subscribers", "global_monitors", "flags"], "no event yet: last_dispatched is left out")
        let row = try #require((tap["subscribers"] as? [[String: Any]])?.first)
        #expect(Set(row.keys) == ["class", "observe", "intercept", "after_dispatch"])
    }

    @Test func aSectionWithoutAProducerIsListedAsAbsent() async throws {
        let debugInput = DebugInput(sources: [InputTapDebugSource(tap: InputEventTap(), mainWork: Self.mainWork())])
        let reply = try await debugInput.reply(to: .read(Set(DebugInputSection.allCases)))
        let object = try Self.object(reply)
        #expect(Set(object.keys) == ["tap", "absent"])
        #expect(reply["absent"] == .array(DebugInputSection.allCases.filter { $0 != .tap }.map { JSONValue.string($0.rawValue) }))
    }

    @Test func aReadOfNamedSectionsLeavesTheOthersOut() async throws {
        let debugInput = DebugInput(sources: Self.everySource(tap: InputEventTap(), resets: Resets()))
        let reply = try await debugInput.reply(to: DebugInput.Request(params: ["sections": .array([.string("gate"), .string("pump")])]))
        #expect(Set(try Self.object(reply).keys) == ["gate", "pump", "absent"])
    }

    // MARK: latency

    @Test func theLatencySectionIsTheReportersLedgerAndResetEmptiesIt() async throws {
        let reporter = InputLatencyReporter()
        let reader = Task.detached(priority: .utility) { await reporter.run() }
        let debugInput = DebugInput(sources: [reporter])
        reporter.submit(Self.latencyBatch())

        let reply = try await debugInput.reply(to: .read([.latency]))
        #expect(reply["absent"] == .array([]))
        #expect(try Self.decode(InputLatencySnapshot.self, reply["latency"]) == Self.latency())

        let reset = try await debugInput.reply(to: DebugInput.Request(params: ["action": .string("reset")]))
        #expect(reset["reset"] == .array([.string("latency")]))
        let after = try await debugInput.reply(to: .read([.latency]))
        let empty = try Self.decode(InputLatencySnapshot.self, after["latency"])
        #expect(empty == InputLatencyLedger().snapshot)
        #expect(empty.rows.isEmpty)
        reporter.finish()
        await reader.value
    }

    @Test func theInteractionsSectionPairsTheReportersKeysAndResetEmptiesIt() async throws {
        let reporter = InputLatencyReporter()
        let reader = Task.detached(priority: .utility) { await reporter.run() }
        let debugInput = DebugInput(sources: [reporter, InteractionLatencyDebugSource(reporter: reporter)])
        var press = InputLatencySlot(kind: .keyPress, target: .palette, entrypoint: .person, keyCode: 36)
        press.generated = 1_000_000
        press.dispatchEnd = 9_000_000
        var release = InputLatencySlot(kind: .keyRelease, target: .palette, entrypoint: .person, keyCode: 36)
        release.generated = 50_000_000
        release.dispatchEnd = 51_000_000
        reporter.submit(InputLatencyBatch(slots: [press, release], vsyncNanos: 16_666_667))

        let reply = try await debugInput.reply(to: .read([.interactions]))
        #expect(reply["absent"] == .array([]))
        let object = try Self.object(reply)
        let section = try #require(object["interactions"] as? [String: Any])
        #expect(Set(section.keys) == ["count", "worst_ms", "high_pct_ms", "kind_of_worst", "target_of_worst"])
        #expect(try Self.decode(InputLatencySnapshot.Interactions.self, reply["interactions"])
            == InputLatencySnapshot.Interactions(count: 1, worstMilliseconds: 8, highPercentileMilliseconds: 8,
                                                 kindOfWorst: "key", targetOfWorst: "palette"))

        _ = try await debugInput.reply(to: DebugInput.Request(params: ["action": .string("reset")]))
        let after = try await debugInput.reply(to: .read([.interactions]))
        #expect(try Self.decode(InputLatencySnapshot.Interactions.self, after["interactions"]) == InputLatencySnapshot.Interactions())
        reporter.finish()
        await reader.value
    }

    // MARK: reset and recorders

    @Test func resetReachesEverySourceAndRecorder() async throws {
        let resets = Resets()
        let debugInput = DebugInput(sources: Self.everySource(tap: InputEventTap(), resets: resets),
                                    recorders: DebugInputRecorderKind.allCases.map { FixedRecorder(kind: $0, resets: resets) })
        let reply = try await debugInput.reply(to: DebugInput.Request(params: ["action": .string("reset")]))
        let everything = DebugInputSection.allCases.map(\.rawValue) + DebugInputRecorderKind.allCases.map(\.rawValue)
        #expect(reply["reset"] == .array(everything.map(JSONValue.string)))
        #expect(await resets.names == everything.filter { $0 != "tap" }, "the tap keeps no counters")
    }

    /// The pump section reads the CEF pump's counters through the App's closures (zeros before
    /// Chromium runs), decodes into its shape, and `reset` reaches the pump.
    @Test func thePumpSectionReadsAndResetsThePumpsCounters() async throws {
        @MainActor final class Pump {
            var counters: DebugInputPump?
            var resets = 0
        }
        let pump = Pump()
        let source = DebugInputPumpSource(read: { pump.counters }, reset: { pump.resets += 1 })
        let debugInput = DebugInput(sources: [source])

        let before = try await debugInput.reply(to: .read([.pump]))
        #expect(try Self.decode(DebugInputPump.self, before["pump"])
            == DebugInputPump(passesWhileInputPending: [:], deferredForInput: 0, passMillisecondsP99: 0))
        pump.counters = Self.pump
        let after = try await debugInput.reply(to: .read([.pump]))
        #expect(try Self.decode(DebugInputPump.self, after["pump"]) == Self.pump)
        _ = try await debugInput.reply(to: DebugInput.Request(params: ["action": .string("reset")]))
        #expect(pump.resets == 1)
    }

    @Test func aRecorderAnswersItsActionWithSinceLaunch() async throws {
        let debugInput = DebugInput(sources: [], recorders: [FixedRecorder(kind: .hops, resets: Resets())])
        let request = try DebugInput.Request(params: ["action": .string("hops"), "since_launch": .bool(true)])
        #expect(request == .record(.hops, sinceLaunch: true))
        let reply = try await debugInput.reply(to: request)
        #expect(reply == .object(["sites": .array([.string("hops.site")]), "since_launch": .bool(true)]))
    }

    @Test func aRecorderThatHasNotLandedAnswersUnavailable() async {
        let debugInput = DebugInput(sources: [])
        for kind in DebugInputRecorderKind.allCases {
            do {
                _ = try await debugInput.reply(to: .record(kind, sinceLaunch: false))
                Issue.record("\(kind.rawValue) answered without a recorder")
            } catch {
                #expect(error.code == "unavailable")
            }
        }
    }

    // MARK: params

    @Test func theParamsParseStrictly() throws {
        #expect(try DebugInput.Request(params: [:]) == .read(Set(DebugInputSection.allCases)))
        #expect(try DebugInput.Request(params: ["action": .string("read")]) == .read(Set(DebugInputSection.allCases)))
        #expect(try DebugInput.Request(params: ["action": .string("dirty")]) == .record(.dirty, sinceLaunch: false))
        #expect(try DebugInput.Request(params: ["action": .string("hittest")]) == .record(.hittest, sinceLaunch: false))
        let invalid: [[String: JSONValue]] = [
            ["action": .string("explode")],
            ["action": .number(1)],
            ["sections": .string("gate")],
            ["sections": .array([.string("nope")])],
            ["action": .string("hops"), "since_launch": .string("yes")],
            ["action": .string("hops"), "sinceLaunch": .bool(true)],
            ["action": .string("hops"), "since-launch": .bool(true)],
            ["action": .string("reset"), "sections": .array([.string("gate")])],
            ["action": .string("read"), "since_launch": .bool(true)],
            ["sections": .array([.string("gate")]), "verbose": .bool(true)],
            ["action": .string("dirty"), "sections": .array([.string("gate")])],
        ]
        for params in invalid {
            do {
                _ = try DebugInput.Request(params: params)
                Issue.record("\(params) parsed")
            } catch {
                #expect(error.code == "invalid_params")
            }
        }
    }

    @Test func aNonFiniteNumberStillEncodes() async throws {
        let gate = DebugInputGate(heldByOrigin: .init(main: 0, offMain: 0), exemptByRule: [:],
                                  maxInputWaitBehindJobsMilliseconds: .infinity, jobsDeferredOverOneFrame: 0,
                                  nonswiftBlocksWhileInputPending: 0)
        let debugInput = DebugInput(sources: [FixedSource(section: .gate, value: gate, resets: Resets())])
        let reply = try await debugInput.reply(to: .read([.gate]))
        #expect(reply["gate"]?["max_input_wait_behind_jobs_ms"] == .string("inf"))
    }
}

/// The test scheduler's display link: never fires, the posted turns run the tap's copy.
@MainActor
private final class DebugInputTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
