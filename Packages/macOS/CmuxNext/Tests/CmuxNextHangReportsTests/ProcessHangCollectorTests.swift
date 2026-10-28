@testable import CmuxNextHangReports
import Foundation
import Testing

/// A Rust process's hang line is a hang-report entry like a watched app thread's: a
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
        off.setEnabled(false)
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

    /// The forwarder reads other processes' lines at launch, before the setting loads: kept until the first read
    /// turns reports on, dropped when it turns them off.
    @Test func theLaunchBacklogIsKeptUntilTheSettingIsRead() throws {
        let on = Self.collector()
        on.noteProcessHang(durationMs: 2_300, frames: Self.frames, thread: Self.dispatch)
        on.setEnabled(true)
        let kept = on.drain().threadHangs
        try #require(kept.count == 1)
        #expect(kept[0].thread == Self.dispatch)

        let off = Self.collector()
        off.noteProcessHang(durationMs: 2_300, frames: Self.frames, thread: Self.dispatch)
        off.setEnabled(false)
        #expect(off.drain().threadHangs.isEmpty)
    }

    /// acpmux and optchat images are cmux's own (RustProcessImages.cmux, the list the line's Sentry event marks
    /// in-app with): the real classifier names their frames, though no such image is loaded in the app.
    @Test func anAcpmuxFrameIsOursThroughTheRealClassifier() throws {
        let classifier = ImageClassifier(appBundlePath: "/Applications/cmux NEXT.app", forbiddenTerms: [],
                                         systemImageExists: { _ in false })
        let collector = HangReportCollector(resolve: { _ in [] }, keepsThreadHangs: true,
                                            resolveForeign: { $0.map { classifier.frame(foreign: $0, loaded: nil) } },
                                            schedule: { $0() })
        collector.setEnabled(true)
        let uuid = "89abcdef-0123-4567-89ab-cdef01234567"
        let frames = [HangReportCollector.ForeignFrame(image: "acpmux", uuid: uuid, offset: 0x40),
                      HangReportCollector.ForeignFrame(image: "optchat-chief", uuid: uuid, offset: 0x80),
                      HangReportCollector.ForeignFrame(image: "libhook.dylib", uuid: uuid, offset: 0x8)]
        collector.noteProcessHang(durationMs: 2_300, frames: frames,
                                  thread: HangSample.WatchedThread(name: "acpmux-blocking", kind: "pool"))
        let kept = collector.drain().threadHangs
        try #require(kept.count == 1)
        #expect(kept[0].frames == [HangReportFrame(image: "acpmux", uuid: uuid.uppercased(), offset: 0x40),
                                   HangReportFrame(image: "optchat-chief", uuid: uuid.uppercased(), offset: 0x80),
                                   .other])
        // A MetricKit frame of the app's own stack keeps the app's list: acpmux is not one of the app's images.
        #expect(classifier.frame(metricKitName: "acpmux", uuid: uuid, offset: 0x40, loaded: nil) == .other)
    }
}
