@testable import CmuxNextTrace
import Foundation
import Testing

/// The keystroke-timing privacy gate (p09-observability-128, rule 5): no key-timing, per-key PTY or flow
/// record leaves the Mac, and none is written while secure input or a password prompt is on.
@Suite("Blackbox privacy")
struct BlackboxPrivacyTests {
    private typealias Name = BlackboxRecord.Name

    private static let action = Name(text: "action.perform", kind: .catalog, categoryBit: 0)
    private static let hang = Name(text: "hang.thread_hung", kind: .catalog, categoryBit: 7)
    /// Every kind of record that times a key: catalog key names, echo hops, PTY hops in other categories,
    /// flows, interned key names and the flow-marked present estimate.
    private static let keyNames: [Name] = [
        Name(text: "key.frame", kind: .catalog, categoryBit: 1),
        Name(text: "key.flow", kind: .catalog, categoryBit: 1),
        Name(text: "key.echo.host_pty_read", kind: .catalog, categoryBit: 1),
        Name(text: "key.echo.renderer", kind: .catalog, categoryBit: 1),
        Name(text: "host.pty_write", kind: .catalog, categoryBit: 6),
        Name(text: "holder.pty.read", kind: .catalog, categoryBit: 6),
        Name(text: "frame.present_estimate", kind: .catalog, categoryBit: 10),
        Name(text: "input.frame", kind: .catalog, categoryBit: 14),
        Name(text: "cef.host_input", kind: .catalog, categoryBit: 4),
        Name(text: "terminal.keystroke", kind: .interned, categoryBit: 1),
    ]

    private static func isKeyRecord(_ record: BlackboxRecord) -> Bool {
        record.name.map(keyNames.contains) ?? false
    }

    /// 100 planted key records among 200 action and hang records, all inside one upload window.
    private static func planted() -> [BlackboxRecord] {
        var records: [BlackboxRecord] = []
        for index in 0..<300 {
            let time = UInt64(1_000 + index)
            if index % 3 == 0 {
                let name = keyNames[(index / 3) % keyNames.count]
                records.append(BlackboxRecord(process: index % 2 == 0 ? .app : .terminalHost, timestamp: time, name: name,
                                              phaseCode: TraceRuntime.Phase.instant.rawValue, arg0: 42, arg1: 0xF10F))
            } else {
                records.append(BlackboxRecord(process: .daemon, timestamp: time, name: index % 2 == 0 ? action : hang,
                                              phaseCode: TraceRuntime.Phase.begin.rawValue, arg0: 3))
            }
        }
        return records
    }

    @Test("100 planted key records give 0 in blackbox[] and keep every other record")
    func plantedKeyRecordsNeverUpload() {
        let records = Self.planted()
        #expect(records.filter(Self.isKeyRecord).count == 100)
        let events = BlackboxUpload().events(records)
        #expect(events.count == 200)
        #expect(events.allSatisfy { $0.name == Self.action || $0.name == Self.hang })
        #expect(events.map(\.timestamp) == events.map(\.timestamp).sorted())
    }

    @Test("100 planted key records give 0 in the crash attachment")
    func plantedKeyRecordsNeverInAttachment() throws {
        let text = try #require(BlackboxUpload().crashAttachmentText(Self.planted(), hangReportsOptIn: true))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 200)
        for name in Self.keyNames { #expect(!text.contains(name.text), "\(name.text)") }
        #expect(!text.contains("pty"))
        #expect(lines.allSatisfy { $0.contains("action.perform") || $0.contains("hang.thread_hung") })
    }

    @Test("The crash attachment needs the hang-reports opt-in")
    func attachmentNeedsOptIn() {
        #expect(BlackboxUpload().crashAttachmentText(Self.planted(), hangReportsOptIn: false) == nil)
        let onlyKeys = Self.planted().filter(Self.isKeyRecord)
        #expect(BlackboxUpload().crashAttachmentText(onlyKeys, hangReportsOptIn: true) == nil)
    }

    @Test("Flow records, interned names and unnamed records never upload")
    func flowsAndNonCatalogNamesDrop() {
        let flows = [TraceRuntime.Phase.flowOut, .flowIn].map { phase in
            BlackboxRecord(process: .daemon, timestamp: 1, name: Self.action, phaseCode: phase.rawValue, arg1: 7)
        }
        let interned = BlackboxRecord(process: .app, timestamp: 2, name: Name(text: "task.site", kind: .interned, categoryBit: 12),
                                      phaseCode: TraceRuntime.Phase.instant.rawValue)
        let unnamed = BlackboxRecord(process: .app, timestamp: 3, name: nil, phaseCode: TraceRuntime.Phase.instant.rawValue)
        #expect(BlackboxUpload().events(flows + [interned, unnamed]).isEmpty)
    }

    @Test("An upload keeps the newest 512 events")
    func uploadKeepsNewest() {
        let records = (0..<600).reversed().map { index in
            BlackboxRecord(process: .app, timestamp: UInt64(index), name: Self.action, phaseCode: TraceRuntime.Phase.instant.rawValue)
        }
        let events = BlackboxUpload().events(records)
        #expect(events.count == BlackboxUpload.maxEvents)
        #expect(events.first?.timestamp == 88)
        #expect(events.last?.timestamp == 599)
    }

    @Test("While secure input is on, 0 key records are written, in the black box and a recording")
    func secureInputWritesNoKeyRecords() {
        let runtime = TraceRuntime(role: .app)
        runtime.setCategoryMask(TraceCategories.blackBoxDefault)
        runtime.categories.setKeyTimingSuppressed(true)
        for _ in 0..<100 { runtime.write(name: 6, categoryBit: TraceCategories.keyBit, phase: .instant) }
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 0)
        // A recording that asks for every category while the password prompt is up.
        runtime.setCategoryMask(.max)
        let keyName = TraceRuntime.InternedName("terminal.keystroke", categoryBit: TraceCategories.keyBit)
        for _ in 0..<100 { runtime.write(keyName, phase: .instant) }
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 0)
        #expect(!runtime.isEnabled(categoryBit: TraceCategories.keyBit))
        runtime.write(name: 1, categoryBit: 0, phase: .instant)
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 1)
    }

    @Test("Ending secure input restores the requested key category")
    func gateRestoresRequest() {
        let categories = TraceCategories(mask: TraceCategories.blackBoxDefault)
        categories.setKeyTimingSuppressed(true)
        #expect(categories.mask == TraceCategories.blackBoxDefault & ~TraceCategories.keyTiming)
        #expect(categories.requestedMask == TraceCategories.blackBoxDefault)
        categories.setMask(0)
        categories.setKeyTimingSuppressed(false)
        #expect(categories.mask == 0)
        categories.setMask(TraceCategories.blackBoxDefault)
        #expect(categories.isEnabled(bit: TraceCategories.keyBit))
    }

    @Test("Racing gate and mask writers settle on the last request and gate")
    func racingWritersSettle() {
        let categories = TraceCategories()
        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            if index % 2 == 0 {
                categories.setKeyTimingSuppressed(index % 4 == 0)
            } else {
                categories.setMask(UInt64(index) | TraceCategories.keyTiming)
            }
        }
        categories.setKeyTimingSuppressed(true)
        #expect(categories.mask & TraceCategories.keyTiming == 0)
        #expect(categories.mask == categories.requestedMask & ~TraceCategories.keyTiming)
    }

    @Test("The black-box default is bits 0-8 and the key bit is trace.md's")
    func catalogBits() {
        #expect(TraceCategories.blackBoxDefault == (0...8).reduce(0) { $0 | 1 << UInt64($1) })
        #expect(TraceCategories.keyBit == 1)
        #expect(TraceCategories.inputBit == 14)
    }
}
