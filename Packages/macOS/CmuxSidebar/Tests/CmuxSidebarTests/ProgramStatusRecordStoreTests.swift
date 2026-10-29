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

    @Test func changedPayloadUsesSafeProtocolFields() {
        var store = ProgramStatusRecordStore()
        let report = ProgramStatusReport(
            state: .blocked,
            kind: .permission,
            progress: 40,
            id: "deploy/eu",
            app: "provider-with-secret-name",
            title: "Apply production credentials",
            message: "token=super-secret"
        )
        store.apply(report)

        let payload = ProgramStatusChangedPayload(report: report, store: store)
        #expect(payload.event == .report)
        #expect(payload.id == "deploy/eu")
        #expect(payload.record?.state == .blocked)
        #expect(payload.record?.kind == .permission)
        #expect(payload.record?.progress == 40)
        #expect(payload.records.map(\.id) == ["deploy/eu"])
    }

    @Test func changedPayloadMapsClearAndLifecycleCleanup() {
        var store = ProgramStatusRecordStore()
        store.apply(ProgramStatusReport(state: .done, id: "lint"))
        store.apply(ProgramStatusReport(state: .clear, id: "build"))

        let clear = ProgramStatusChangedPayload(
            report: ProgramStatusReport(state: .clear, id: "build"),
            store: store
        )
        #expect(clear.event == .clear)
        #expect(clear.id == "build")
        #expect(clear.record == nil)
        #expect(clear.records.map(\.id) == ["lint"])

        let cleanup = ProgramStatusChangedPayload(
            event: .transientDrop,
            store: store
        )
        #expect(cleanup.event == .transientDrop)
        #expect(cleanup.id == nil)
        #expect(cleanup.record == nil)
        #expect(cleanup.records.map(\.id) == ["lint"])
    }

    @Test func changedPayloadMapsTerminalRemovalAndAdoption() {
        var store = ProgramStatusRecordStore()
        store.apply(ProgramStatusReport(state: .working, progress: 30, id: "build", app: "cargo"))

        let removed = ProgramStatusChangedPayload(event: .removed, store: ProgramStatusRecordStore())
        #expect(removed.event.rawValue == "removed")
        #expect(removed.id == nil)
        #expect(removed.record == nil)
        #expect(removed.records.isEmpty)

        let adopted = ProgramStatusChangedPayload(event: .adopted, store: store)
        #expect(adopted.event.rawValue == "adopted")
        #expect(adopted.id == nil)
        #expect(adopted.record == nil)
        #expect(adopted.records.map(\.id) == ["build"])
        #expect(adopted.records.first?.progress == 30)
    }
}
