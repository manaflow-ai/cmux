import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import SwiftUI
import Testing

/// Detector, Mac half (Leo, 2026-11-21: "these messages should not be pushing up the text ... a symbol or short
/// thing, not a sentence. stop layout shifting"): a fixed list surface laid out connected, reconnecting and
/// offline keeps every row's frame; the chip is an overlay. The same list with the old placement (a sentence row
/// above it) is measured too: that is the before number, and it must stay a shift so the probe is known to see one.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct ConnectionChipLayoutShiftTests {
    enum Link: String, CaseIterable { case connected, reconnecting, offline }

    static func word(_ link: Link) -> String? {
        switch link {
        case .connected: nil
        case .reconnecting: "Reconnecting"
        case .offline: "Offline"
        }
    }

    struct Rows: View {
        let frames: LayoutFrames
        var body: some View {
            VStack(spacing: 0) {
                ForEach(0 ..< 8, id: \.self) { index in
                    Text(verbatim: "Row \(index)")
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .layoutProbe("row\(index)", into: frames)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The chip, shown at once (the bound is the gate's job, tested below): the rows never move.
    @Test func aConnectionChipNeverMovesTheRows() async {
        var base: [String: CGRect] = [:]
        var report: [String] = []
        for link in Link.allCases {
            let frames = await LayoutShiftProbe.measure { frames in
                Rows(frames: frames)
                    .connectionChip(Self.word(link))
                    .environment(\.connectionQuietDelay, .zero)
            }
            if link == .connected {
                base = frames
                #expect(frames.count == 8, "rows laid out: \(frames.count)")
                continue
            }
            let points = LayoutShiftProbe.shift(frames, from: base)
            report.append("\(link.rawValue): \(points) pt")
            #expect(points == 0, "\(link.rawValue): the rows moved \(points) pt")
        }
        print("ConnectionChipLayoutShift: " + report.joined(separator: ", "))
    }

    /// The placement it replaces, a sentence row above the list, moves the rows: the probe sees a shift.
    @Test func aSentenceRowAboveTheListMovesTheRows() async {
        func measure(_ link: Link) async -> [String: CGRect] {
            await LayoutShiftProbe.measure { frames in
                VStack(spacing: 0) {
                    if let word = Self.word(link) {
                        Text(verbatim: "\(word)… your link will come back on its own.").padding(8)
                    }
                    Rows(frames: frames)
                }
            }
        }
        let base = await measure(.connected)
        let shifted = await measure(.reconnecting)
        let points = LayoutShiftProbe.shift(shifted, from: base)
        print("ConnectionChipLayoutShift before (sentence row): \(points) pt")
        #expect(points > 0, "the probe must see a row placed above the list")
    }

    @MainActor final class Seen { var lasted = false }

    struct Gate: View {
        let seen: Seen
        @State private var lasted = false
        var body: some View {
            Color.clear
                .connectionLasting(true, lasted: $lasted)
                .onChange(of: lasted) { _, now in seen.lasted = now }
        }
    }

    private func lasted(delay: Duration?) async -> Bool {
        let seen = Seen()
        _ = await LayoutShiftProbe.measure { _ in
            if let delay { AnyView(Gate(seen: seen).environment(\.connectionQuietDelay, delay)) } else { AnyView(Gate(seen: seen)) }
        }
        return seen.lasted
    }

    /// Under the bound a link state draws nothing; past it, it shows.
    @Test func theChipWaitsTheSharedBound() async {
        #expect(NoticeTiming.connectionQuiet == .seconds(10))
        #expect(await lasted(delay: nil) == false, "a link state under 10 s shows nothing")
        #expect(await lasted(delay: .milliseconds(20)) == true, "a link state past its bound shows")
    }

    /// A link state is a chip a word or two wide, never a sentence.
    @Test func aChipIsAWordOrTwo() {
        for link in Link.allCases.dropFirst() {
            let word = Self.word(link) ?? ""
            #expect(word.split(separator: " ").count <= 2)
            let size = NSHostingView(rootView: ConnectionChip(word)).fittingSize
            #expect(size.width <= 140, "\(word): \(size.width) pt wide")
            #expect(size.height <= 24, "\(word): \(size.height) pt tall")
        }
    }
}
