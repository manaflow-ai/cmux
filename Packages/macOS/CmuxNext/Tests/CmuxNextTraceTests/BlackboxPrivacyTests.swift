import CmuxNextCompat
@testable import CmuxNextTrace
import Foundation
import Testing

/// The keystroke-timing privacy gate: no key-timing, per-key PTY or flow
/// record leaves the Mac, and none is written while secure input or a password prompt is on.
@Suite(.serialized)
struct BlackboxPrivacyTests {
    private typealias Record = TraceBlackBoxUpload.Record
    private typealias Name = TraceBlackBoxUpload.Record.Name

    private static let action = Name(text: "action.perform", kind: .catalog, categoryBit: 0)
    private static let hang = Name(text: "hang.thread_hung", kind: .catalog, categoryBit: 7)
    /// Every kind of record that times a key: catalog key names, echo hops, PTY hops in other categories, the
    /// per-input events, an interned key name and the flow-marked present estimate.
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

    private static func isKeyRecord(_ record: Record) -> Bool {
        record.name.map(keyNames.contains) ?? false
    }

    /// 100 planted key records among 200 action and hang records, all inside one upload window.
    private static func planted() -> [Record] {
        (0 ..< 300).map { index -> Record in
            let time = UInt64(1_000 + index)
            guard index % 3 != 0 else {
                return Record(process: index % 2 == 0 ? .app : .terminalHost, timestamp: time,
                              name: keyNames[(index / 3) % keyNames.count],
                              phaseCode: TraceRecord.Phase.instant.rawValue, arg0: 42, arg1: 0xF10F)
            }
            return Record(process: .daemon, timestamp: time, name: index % 2 == 0 ? action : hang,
                          phaseCode: TraceRecord.Phase.begin.rawValue, arg0: 3)
        }
    }

    @Test("100 planted key records give 0 in blackbox[] and keep every other record")
    func plantedKeyRecordsNeverUpload() {
        let records = Self.planted()
        #expect(records.filter(Self.isKeyRecord).count == 100)
        let events = TraceBlackBoxUpload().events(records)
        #expect(events.count == 200)
        #expect(events.allSatisfy { $0.name == Self.action || $0.name == Self.hang })
        #expect(events.map(\.timestamp) == events.map(\.timestamp).sorted())
    }

    @Test("100 planted key records give 0 in the crash attachment")
    func plantedKeyRecordsNeverInAttachment() throws {
        let text = try #require(TraceBlackBoxUpload().crashAttachmentText(Self.planted(), hangReportsOptIn: true))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 200)
        for name in Self.keyNames { #expect(!text.contains(name.text), "\(name.text)") }
        #expect(!text.contains("pty"))
        #expect(lines.allSatisfy { $0.contains("action.perform") || $0.contains("hang.thread_hung") })
        #expect(lines.first == "1001 daemon hang.thread_hung B 3 0")
    }

    @Test("The crash attachment needs the hang-reports opt-in")
    func attachmentNeedsOptIn() {
        #expect(TraceBlackBoxUpload().crashAttachmentText(Self.planted(), hangReportsOptIn: false) == nil)
        let onlyKeys = Self.planted().filter(Self.isKeyRecord)
        #expect(TraceBlackBoxUpload().crashAttachmentText(onlyKeys, hangReportsOptIn: true) == nil)
    }

    @Test("Flow records, interned names, unknown kinds and unnamed records never upload")
    func flowsAndNonCatalogNamesDrop() {
        let flows = [TraceRecord.Phase.flowOut, .flowIn].map { phase in
            Record(process: .daemon, timestamp: 1, name: Self.action, phaseCode: phase.rawValue, arg1: 7)
        }
        let interned = Record(process: .app, timestamp: 2, name: Name(text: "task.site", kind: .interned, categoryBit: 12),
                              phaseCode: TraceRecord.Phase.instant.rawValue)
        let unknownKind = Record(process: .app, timestamp: 3, name: Name(text: "action.perform", kind: nil, categoryBit: 0),
                                 phaseCode: TraceRecord.Phase.instant.rawValue)
        let unnamed = Record(process: .app, timestamp: 4, name: nil, phaseCode: TraceRecord.Phase.instant.rawValue)
        #expect(TraceBlackBoxUpload().events(flows + [interned, unknownKind, unnamed]).isEmpty)
    }

    @Test("An upload keeps the newest 512 events")
    func uploadKeepsNewest() {
        let records = (0 ..< 600).reversed().map { index in
            Record(process: .app, timestamp: UInt64(index), name: Self.action, phaseCode: TraceRecord.Phase.instant.rawValue)
        }
        let events = TraceBlackBoxUpload().events(records)
        #expect(events.count == TraceBlackBoxUpload.maxEvents)
        #expect(events.first?.timestamp == 88)
        #expect(events.last?.timestamp == 599)
    }

    @Test("A real ring with 100 key records decodes to 0 key records in the upload")
    func ringImageDropsKeyRecords() throws {
        let catalog = TraceRing.nameTable(
            names: [(id: 1, category: 0, text: "action.perform"), (id: 2, category: 1, text: "key.frame"),
                    (id: 3, category: 1, text: "key.echo.host_pty_read"), (id: 4, category: 10, text: "frame.present_estimate")],
            categories: [(bit: 0, text: "action"), (bit: 1, text: "key"), (bit: 10, text: "frame")]
        )
        let ring = TraceRing(sizes: TraceRing.Sizes(nameCapacity: 64, threadCapacity: 256, chunkCount: 64),
                             identity: TraceRing.Identity(pid: 9, role: .daemon), catalog: catalog)
        for index in 0 ..< 150 {
            let keyNames: [UInt16] = [2, 3, 4]
            let name: UInt16 = index % 3 == 2 ? 1 : keyNames[(index / 3) % 3]
            ring.write(name: name, phase: .instant, timestamp: 100 + UInt64(index), arg0: UInt64(index))
        }
        let image = try #require(ring.decodedImage())
        let records = TraceBlackBoxUpload.records(of: image)
        #expect(records.count == 150)
        #expect(records.allSatisfy { $0.process == .daemon })
        #expect(records.filter { $0.name?.text != "action.perform" }.count == 100)
        let events = TraceBlackBoxUpload().events(records)
        #expect(events.count == 50)
        #expect(events.allSatisfy { $0.name?.text == "action.perform" })
    }

    @Test("While secure input is on, 0 key records are written, in the black box and a recording")
    func secureInputWritesNoKeyRecords() {
        let runtime = TraceRuntime(role: .app)
        runtime.setCategories(.blackBox)
        runtime.setKeyTimingSuppressed(true, by: .terminalSecureInput)
        for _ in 0 ..< 100 { runtime.write(name: 6, categoryBit: 1, phase: .instant) }
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 0)
        // A recording that asks for every category while the password prompt is up.
        runtime.setCategories(.all)
        let keyName = TraceRuntime.InternedName("terminal.keystroke", categoryBit: 1)
        for _ in 0 ..< 100 { runtime.write(keyName, phase: .instant) }
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 0)
        #expect(!runtime.isEnabled(.key))
        #expect(runtime.requestedCategoryMask == TraceCategories.all.rawValue)
        runtime.write(name: 1, categoryBit: 0, phase: .instant)
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 1)
    }

    @Test("While secure input is on, the attached ring holds 0 key records and its header says so")
    func secureInputKeepsKeysOutOfTheRing() throws {
        let runtime = TraceRuntime(role: .app)
        let ring = TraceRing(records: 1_024, role: .app)
        runtime.attach(ring)
        runtime.setCategories(.blackBox)
        runtime.setKeyTimingSuppressed(true, by: .secureEventInput)
        for index in 0 ..< 100 { runtime.write(name: 6, categoryBit: 1, phase: .instant, arg0: UInt64(index)) }
        runtime.write(name: 1, categoryBit: 0, phase: .instant)
        #expect(ring.records().map(\.name) == [1])
        let image = try #require(ring.decodedImage())
        #expect(!TraceCategories(rawValue: image.header.categories).contains(.key))
    }

    @Test("Ending secure input restores the requested key category")
    func gateRestoresRequest() {
        let runtime = TraceRuntime(role: .app)
        runtime.setCategories(.blackBox)
        runtime.setKeyTimingSuppressed(true, by: .terminalSecureInput)
        #expect(runtime.categories == TraceCategories.blackBox.subtracting(.key))
        #expect(runtime.isKeyTimingSuppressed)
        runtime.setCategoryMask(0)
        runtime.setKeyTimingSuppressed(false, by: .terminalSecureInput)
        #expect(runtime.categoryMask == 0)
        runtime.setCategories(.blackBox)
        #expect(runtime.isEnabled(.key))
        #expect(TraceCategories.all.gated(keyTimingSuppressed: false) == .all)
    }

    @Test("Two overlapping holds: releasing one keeps the gate closed until the other lets go")
    func overlappingHoldsKeepTheGateClosed() {
        let runtime = TraceRuntime(role: .app)
        runtime.setCategories(.blackBox)
        runtime.setKeyTimingSuppressed(true, by: .terminalSecureInput)
        runtime.setKeyTimingSuppressed(true, by: .secureEventInput)
        #expect(runtime.keyTimingHolds == [.terminalSecureInput, .secureEventInput])
        runtime.setKeyTimingSuppressed(false, by: .terminalSecureInput)
        #expect(runtime.keyTimingHolds == .secureEventInput)
        #expect(runtime.isKeyTimingSuppressed)
        for _ in 0 ..< 100 { runtime.write(name: 6, categoryBit: 1, phase: .instant) }
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 0)
        // Releasing a hold twice, or one that was never set, changes nothing.
        runtime.setKeyTimingSuppressed(false, by: .terminalSecureInput)
        #expect(runtime.isKeyTimingSuppressed)
        runtime.setKeyTimingSuppressed(false, by: .secureEventInput)
        #expect(!runtime.isKeyTimingSuppressed)
        #expect(runtime.isEnabled(.key))
        runtime.write(name: 6, categoryBit: 1, phase: .instant)
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 1)
    }

    @Test("Racing request and hold writers leave the flags and the ring header at the final request and holds")
    func racingWritersSettle() throws {
        let runtime = TraceRuntime(role: .app)
        let ring = TraceRing(records: 1_024, role: .app)
        runtime.attach(ring)
        let holds: [TraceRuntime.KeyTimingHold] = [.terminalSecureInput, .secureEventInput]
        for round in 0 ..< 300 {
            DispatchQueue.concurrentPerform(iterations: 48) { index in
                switch index % 3 {
                case 0: runtime.setCategoryMask(UInt64(truncatingIfNeeded: round &* 48 &+ index) | TraceCategories.key.rawValue)
                case 1: runtime.setKeyTimingSuppressed((index / 3 + round) % 2 == 0, by: holds[(index / 3) % 2])
                default: runtime.setKeyTimingSuppressed((index / 3 + round) % 3 == 0, by: holds[(index / 3 + 1) % 2])
                }
            }
            // No publish after the writers join: what they left must already match.
            let expected = TraceCategories(rawValue: runtime.requestedCategoryMask)
                .gated(keyTimingSuppressed: runtime.isKeyTimingSuppressed).rawValue
            #expect(runtime.categoryMask == expected, "round \(round)")
            let header = try #require(ring.decodedImage()).header.categories
            #expect(header == runtime.categoryMask, "round \(round)")
        }
    }

    @Test("The categories that never upload are key and input")
    func neverUploadedBits() {
        #expect(TraceCategories.keyTiming == .key)
        #expect(TraceCategories.neverUploaded == [.key, .input])
        #expect(TraceCategories.neverUploaded.rawValue == 1 << 1 | 1 << 14)
    }
}
