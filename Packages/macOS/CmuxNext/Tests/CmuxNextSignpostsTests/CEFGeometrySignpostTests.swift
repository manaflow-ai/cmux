import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// The `cef.geometry` slice and instants and the `cef.host_input` instant (perf-hot
/// `cef-geometry` and `cef-host-input`): a geometry slice is one B/E pair with its source in the B and the catcher
/// panels shown and moved in the E, a page view's post is one instant inside it, and an input frame sent to the
/// Chromium host is one instant with its wire kind, which the keystroke-timing gate drops for key and edit frames.
/// Both are recording only: the black box alone records none of them. Each test records into its own runtime.
@Suite struct CEFGeometrySignpostTests {
    private nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        func runtime() -> TraceRuntime {
            TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
        }
    }

    private struct Rig {
        let log = RecordLog()
        let runtime: TraceRuntime
        let cef: Signposter

        /// A recording: the black box plus every recording category.
        init(categories: TraceCategories = .all) {
            runtime = log.runtime()
            runtime.setCategories(categories)
            cef = Signposter(category: .cef, mirror: SignpostMetricKitMirror(), trace: runtime)
        }

        func records(_ name: SignpostName) -> [TraceRuntime.StubRecord] {
            log.records.filter { $0.name == name.rawValue }
        }
    }

    @Test func aGeometryChangeIsOneSliceWithItsPostsInside() {
        let rig = Rig()
        let interval = rig.cef.beginCEFGeometry(.parentGeometry)
        rig.cef.cefGeometryPost()
        rig.cef.cefGeometryPost()
        rig.cef.endCEFGeometry(interval, catchers: 3, panelMoves: 2)

        let records = rig.records(.cefGeometry)
        #expect(records.map(\.phase) == [.begin, .instant, .instant, .end])
        #expect(records.first?.arg0 == Signposter.CEFGeometrySource.parentGeometry.rawValue)
        #expect(records.last?.arg0 == 3)
        #expect(records.last?.arg1 == 2)
        #expect(interval.isTraced)
    }

    @Test func aCatcherSyncCarriesItsOwnSource() {
        let rig = Rig()
        rig.cef.endCEFGeometry(rig.cef.beginCEFGeometry(.catcherSync), catchers: 0, panelMoves: 0)

        let records = rig.records(.cefGeometry)
        #expect(records.map(\.phase) == [.begin, .end])
        #expect(records.first?.arg0 == Signposter.CEFGeometrySource.catcherSync.rawValue)
    }

    @Test func nothingIsRecordedWithTheCEFCategoryOff() {
        let rig = Rig(categories: TraceCategories.all.subtracting(.cef))
        let interval = rig.cef.beginCEFGeometry(.parentGeometry)
        rig.cef.cefGeometryPost()
        rig.cef.cefHostInput(.mouse)
        rig.cef.endCEFGeometry(interval, catchers: 1, panelMoves: 1)

        #expect(!interval.isTraced)
        #expect(rig.log.records.isEmpty)
    }

    /// The black box fires at most once per person action: a live resize or a mouse sweep must not push the
    /// action, key and switch records out of it.
    @Test func theBlackBoxAloneRecordsNoGeometryAndNoHostInput() {
        let rig = Rig(categories: .blackBox)
        let interval = rig.cef.beginCEFGeometry(.parentGeometry)
        rig.cef.cefGeometryPost()
        rig.cef.endCEFGeometry(interval, catchers: 1, panelMoves: 1)
        for kind in Signposter.CEFHostInputKind.allCases { rig.cef.cefHostInput(kind) }

        #expect(!interval.isTraced)
        #expect(rig.records(.cefGeometry).isEmpty)
        #expect(rig.records(.cefHostInput).isEmpty)
    }

    @Test func aGeometryBeginRecordedBeforeTheRecordingStopsStillEnds() {
        let rig = Rig()
        let interval = rig.cef.beginCEFGeometry(.parentGeometry)
        rig.runtime.setCategories(.blackBox)
        rig.cef.endCEFGeometry(interval, catchers: 0, panelMoves: 0)

        #expect(rig.records(.cefGeometry).map(\.phase) == [.begin, .end])
    }

    @Test func aHostInputIsOneInstantWithItsWireKind() {
        let rig = Rig()
        rig.cef.cefHostInput(.mouse)
        rig.cef.cefHostInput(.key)
        rig.cef.cefHostInput(.edit)

        let records = rig.records(.cefHostInput)
        #expect(records.map(\.phase) == [.instant, .instant, .instant])
        #expect(records.map(\.arg0) == [3, 5, 10])
    }

    @Test func theKeystrokeTimingGateDropsKeyAndEditFrames() {
        let rig = Rig()
        rig.runtime.setKeyTimingSuppressed(true, by: .terminalSecureInput)
        for kind in Signposter.CEFHostInputKind.allCases { rig.cef.cefHostInput(kind) }

        #expect(rig.records(.cefHostInput).map(\.arg0) == [3, 4])
        #expect(Signposter.CEFHostInputKind.allCases.filter(\.carriesKeyTiming) == [.key, .edit])
    }
}
