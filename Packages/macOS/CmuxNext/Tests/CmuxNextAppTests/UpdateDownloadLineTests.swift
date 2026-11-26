import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import Foundation
import Testing

/// Leo 2026-11-05, on the Downloading Update card reading "115 MB of 265.3 MB · 43%": "insane layout
/// shift with the downloading update. Like, why is it that as the left number grows, it just keeps
/// shifting?". The bytes line keeps one width while it counts, and the card's bar and text keep their
/// frames through every loading stage, whether the cancel shows or not.
@MainActor @Suite(.serialized) struct UpdateDownloadLineTests {
    static let mb: UInt64 = 1_000_000
    static let expected: UInt64 = 265_300_000

    static func notice(_ card: UpdateCard) -> SidebarNoticeCard {
        SidebarCardFeed.notice(card.presentation(version: "1.0.0", build: "100"), asked: true)
    }

    static func width(_ text: String, _ font: NSFont = Typography.system(.monospacedDigit, size: TypeScale.caption)) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    @Test func theBytesLineKeepsItsWidthWhileItCounts() throws {
        var widths: Set<Int> = [], ofOffsets: Set<Int> = []
        for received in Array(stride(from: UInt64(0), through: Self.expected, by: 3_700_000)) + [Self.expected] {
            let text = try #require(UpdateTransfer.downloading(received: received, expected: Self.expected).bytesText)
            widths.insert(Int((Self.width(text) * 4).rounded()))
            let of = try #require(text.range(of: " of "), "no \" of \" in \(text)")
            ofOffsets.insert(Int((Self.width(String(text[..<of.lowerBound])) * 4).rounded()))
        }
        #expect(widths.count == 1, "the bytes line changes width as it counts: \(widths.sorted())")
        #expect(ofOffsets.count == 1, "\"of\" moves as the received count grows: \(ofOffsets.sorted())")
    }

    /// Every other counting percent in the update flow keeps its width too: going back's notice and the
    /// Channels switch's button (both draw tabular digits), and Getting the Newest keeps its detail line
    /// from before the first byte, so the card does not grow a line when bytes start.
    @Test func everyUpdatePercentKeepsItsWidthWhileItCounts() throws {
        var revert: Set<Int> = [], channels: Set<Int> = []
        for whole in [0, 1, 7, 42, 99, 100] {
            let fraction = Double(whole) / 100
            let back = try #require(RevertNotice(RevertProgress(step: .downloading, fraction: fraction)).detail)
            revert.insert(Int((Self.width(back) * 4).rounded()))
            let label = BuildSwitchProgress(build: "1", stage: .download, fraction: fraction).label
            channels.insert(Int((Self.width(label) * 4).rounded()))
        }
        #expect(revert.count == 1, "going back's percent changes width as it counts: \(revert.sorted())")
        #expect(channels.count == 1, "the Channels switch's percent changes width as it counts: \(channels.sorted())")
        let before = UpdateCard.gettingNewest(nil, pulled: false).presentation(version: "1.0.0", build: "100")
        let counting = UpdateCard.gettingNewest(.downloading(received: Self.mb, expected: Self.expected), pulled: false)
            .presentation(version: "1.0.0", build: "100")
        #expect(before.detail != nil && counting.detail != nil, "Getting the Newest gains a detail line when bytes start")
    }

    @Test func bothCountsReadInTheSizesUnitWithOneDecimal() throws {
        let text = try #require(UpdateTransfer.downloading(received: 115 * Self.mb, expected: Self.expected).bytesText)
        #expect(text.contains("115.0 MB"), "a whole count drops its decimal: \(text)")
        #expect(text.contains("265.3 MB"))
        let early = try #require(UpdateTransfer.downloading(received: 900_000, expected: Self.expected).bytesText)
        #expect(early.contains("0.9 MB"), "an early count reads in another unit than the size: \(early)")
        let almost = try #require(UpdateTransfer.downloading(received: Self.expected - 1, expected: Self.expected).bytesText)
        #expect(!almost.contains("100%"), "the line reads 100% before the last byte: \(almost)")
    }

    @Test func theBarAndTextKeepTheirFramesThroughEveryLoadingStage() {
        let stages: [UpdateCard] = [
            .checking,
            .downloading(.starting),
            .downloading(.downloading(received: 12 * Self.mb, expected: Self.expected)),
            .downloading(.preparing(0.5)),
            .installing,
        ]
        let card = SidebarNoticeCardView(motionPolicy: { MotionPolicy(speed: .fast, reduceMotion: true) })
        var tracks: Set<String> = []
        for stage in stages {
            let notice = Self.notice(stage)
            card.frame = NSRect(x: 0, y: 0, width: 240, height: SidebarNoticeCardView.height(for: notice, width: 240))
            card.configure(notice)
            card.layoutSubtreeIfNeeded()
            tracks.insert(NSStringFromRect(card.track.frame))
        }
        #expect(tracks.count == 1, "the bar moves or resizes between loading stages: \(tracks.sorted())")
    }
}
