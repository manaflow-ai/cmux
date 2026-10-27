@testable import CmuxNextHangReports
import Foundation
import Testing

/// A Rust process's hang line (p09-observability-075) is a hang-report entry like a watched app thread's: a
/// `hangwatch` sample that names the thread, its frames classified by the foreign resolver, kept only while
/// reports are on, the schema carries thread hangs and the line has a stack.
struct ProcessHangCollectorTests {
    private static let ours = HangReportFrame(image: "cmux-tui", uuid: "01234567-89AB-CDEF-1032-547698BADCFE", offset: 0x10)
    private static let dispatch = HangSample.WatchedThread(name: "mux-control-dispatch", kind: "control")
    private static let frames = [HangReportCollector.ForeignFrame(image: "cmux-tui", uuid: "01234567-89ab-cdef-1032-547698badcfe", offset: 0x10),
                                 HangReportCollector.ForeignFrame(image: nil, uuid: nil, offset: nil)]

    private static func collector(keepsThreadHangs: Bool = true, foreign: Bool = true) -> HangReportCollector {
        let classify: HangReportCollector.ResolveForeign = { frames in
            frames.map { frame -> HangReportFrame in frame.image == nil ? HangReportFrame.other : Self.ours }
        }
        return HangReportCollector(resolve: { _ in [] }, keepsThreadHangs: keepsThreadHangs,
                                   resolveForeign: foreign ? classify : nil, schedule: { $0() })
    }

    @Test func aProcessHangIsKeptWithItsThreadAndClassifiedFrames() throws {
        let collector = Self.collector()
        collector.setEnabled(true)
        collector.noteProcessHang(durationMs: 2_300, frames: Self.frames, thread: Self.dispatch)
        let kept = collector.drain().threadHangs
        try #require(kept.count == 1)
        #expect(kept[0].source == .hangWatch)
        #expect(kept[0].kind == .hang)
        #expect(kept[0].durationMs == 2_300)
        #expect(kept[0].thread == Self.dispatch)
        #expect(kept[0].frames == [Self.ours, .other])
    }

    @Test func nothingIsKeptWhileOffWithoutTheSchemaOrAResolverOrAStack() {
        let off = Self.collector()
        off.noteProcessHang(durationMs: 2_300, frames: Self.frames, thread: Self.dispatch)
        #expect(off.drain().threadHangs.isEmpty)

        for collector in [Self.collector(keepsThreadHangs: false), Self.collector(foreign: false)] {
            collector.setEnabled(true)
            collector.noteProcessHang(durationMs: 2_300, frames: Self.frames, thread: Self.dispatch)
            #expect(collector.drain().threadHangs.isEmpty)
        }

        let noStack = Self.collector()
        noStack.setEnabled(true)
        noStack.noteProcessHang(durationMs: 2_300, frames: [], thread: Self.dispatch)
        #expect(noStack.drain().threadHangs.isEmpty)
    }
}
