import CmuxSidebar
import Testing

@Suite("OSC 7501 record store")
struct ProgramStatusRecordStoreTests {
    @Test func reportsReplaceRecordsAndClearSubtrees() {
        var store = ProgramStatusRecordStore()
        store.apply(ProgramStatusReport(state: .working, id: "build", app: "cargo"))
        store.apply(ProgramStatusReport(state: .blocked, kind: .question, id: "build/test"))
        store.apply(ProgramStatusReport(state: .done, id: "build", message: "done"))
        #expect(store.record(id: "build")?.state == .done)
        // A report replaces its record completely, so the earlier app is gone.
        #expect(store.record(id: "build")?.app == nil)
        #expect(store.record(id: "build/test")?.state == .blocked)
        store.apply(ProgramStatusReport(state: .clear, id: "build"))
        #expect(store.records.isEmpty)
    }

    @Test func rootClearAndLRUEviction() {
        var store = ProgramStatusRecordStore()
        for index in 0..<ProgramStatusRecordStore.recordLimit {
            store.apply(ProgramStatusReport(state: .done, id: "id-\(index)"))
        }
        store.apply(ProgramStatusReport(state: .done, id: "new"))
        #expect(store.records.count == ProgramStatusRecordStore.recordLimit)
        #expect(store.record(id: "id-0") == nil)
        store.apply(ProgramStatusReport(state: .clear))
        #expect(store.records.isEmpty)
    }

    @Test func inheritanceAndLifetimeRules() {
        var store = ProgramStatusRecordStore()
        store.apply(ProgramStatusReport(state: .working, id: "deploy", app: "terraform"))
        store.apply(ProgramStatusReport(state: .blocked, kind: .permission, progress: 40, id: "deploy/eu"))
        #expect(store.effectiveApp(for: store.record(id: "deploy/eu")!) == "terraform")
        store.dropTransient()
        #expect(store.records.isEmpty)
        store.apply(ProgramStatusReport(state: .done, id: "done"))
        store.apply(ProgramStatusReport(state: .error, id: "failed"))
        store.dismissCompleted()
        #expect(store.records.isEmpty)
    }

    @Test func promptStartDropsOnlyTransientRecords() {
        var store = ProgramStatusRecordStore()
        store.apply(ProgramStatusReport(state: .working, id: "working"))
        store.apply(ProgramStatusReport(state: .blocked, id: "blocked"))
        store.apply(ProgramStatusReport(state: .idle, id: "idle"))
        store.apply(ProgramStatusReport(state: .done, id: "done"))
        store.apply(ProgramStatusReport(event: .promptStart, state: .idle))
        #expect(store.record(id: "working") == nil)
        #expect(store.record(id: "blocked") == nil)
        #expect(store.record(id: "idle") != nil)
        #expect(store.record(id: "done") != nil)
    }
}
