#if DEBUG
import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// The Agent Messages Playground's header variants (user 2026-11-02, msg 19613: "i want playground in swift"):
/// every style turns a fold, an opened fold and a note into one drawn row that keeps its style,
/// is as tall as the style says and draws something, so switching the playground never leaves a blank or a
/// mis-sized row. The provider is used directly (no registration), so the shipped look of other suites stays.
@MainActor @Suite struct HomeAgentFoldStyleTests {
    static let group = "0123456789abcdef"

    static func rows() -> [(String, HomeAgentMessageRow)] {
        var fold = HomeAgentMessageRow(group: group, kind: .fold(count: 4, peers: ["a959", "a931", "a940"], expanded: false))
        fold.peerStates = [.reported, .told, .told]
        fold.latest = "Done: both rows now start at 12 pt."
        var open = fold
        open.kind = .fold(count: 4, peers: ["a959", "a931", "a940"], expanded: true)
        let note = HomeAgentMessageRow(group: group, kind: .note(peer: "a933", reason: .stopped(session: "Disconnected"),
                                                                 text: "stopped without a report: its session is Disconnected"))
        return [("fold", fold), ("open fold", open), ("note", note)]
    }

    @Test(arguments: HomeAgentFoldStyle.allCases)
    func everyStyleDrawsEveryRowAtItsOwnHeight(style: HomeAgentFoldStyle) throws {
        let provider = HomeAgentFoldRowProvider(style: style.rawValue)
        for (name, row) in Self.rows() {
            let part = try #require(provider.part(row), "\(style.title), \(name): no row")
            guard case let .custom(custom) = part else { Issue.record("\(style.title), \(name): not a drawn row"); continue }
            let payload = try #require(HomeAgentFoldRowProvider.payload(custom))
            #expect(payload.style == style.rawValue, "\(style.title), \(name)")
            let height = provider.measure(custom, maxWidth: 420).height
            #expect(height == style.height(payload), "\(style.title), \(name): measured \(height)")
            #expect(height >= (style.spacing == nil ? HomeAgentFoldRowProvider.height : 16), "\(style.title), \(name)")
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let ctx = try #require(CGContext(data: nil, width: 420, height: Int(height.rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.translateBy(x: 0, y: height)
            ctx.scaleBy(x: 1, y: -1)
            provider.drawRow(custom, in: ctx, rect: CGRect(x: 0, y: 0, width: 420, height: height),
                             context: CustomRowDrawContext(outgoing: false, isDark: false, elevated: false))
            let data = try #require(ctx.makeImage()?.dataProvider?.data as Data?)
            #expect(data.contains { $0 > 0 }, "\(style.title), \(name): drew nothing")
        }
    }

    @Test func theFoldCarriesEachAgentsStateAndTheNewestWords() throws {
        let provider = HomeAgentFoldRowProvider(style: HomeAgentFoldStyle.statusDots.rawValue)
        let part = try #require(provider.part(Self.rows()[0].1))
        guard case let .custom(custom) = part else { Issue.record("not a drawn row"); return }
        let payload = try #require(HomeAgentFoldRowProvider.payload(custom))
        #expect(payload.peers == ["a959", "a931", "a940"])
        #expect(payload.states == ["reported", "told", "told"])
        #expect(payload.latest == "Done: both rows now start at 12 pt.")
        #expect(payload.count == 4 && payload.role == "fold")
    }

    /// The spacing variants (user 2026-11-02, msg 19733): each one changes the shipped line's spacing, and no two
    /// are the same, so every pick in the playground shows something new.
    @Test func everySpacingVariantDiffersFromTheShippedLineAndTheOthers() {
        let spacings = HomeAgentFoldStyle.allCases.compactMap(\.spacing)
        #expect(spacings.count >= 10)
        #expect(!spacings.contains(.shipped))
        for (i, a) in spacings.enumerated() { for b in spacings.dropFirst(i + 1) { #expect(a != b) } }
    }

    /// The pill styles (user 2026-11-03, msg 19960): one pill per agent, named by its title, and a click opens the
    /// agent whose pill it lands on (between pills, or on a note, the row folds as before).
    @Test(arguments: [HomeAgentFoldStyle.pills, .pillsTwoLine, .pillChips])
    func aClickOnAPillOpensThatAgent(style: HomeAgentFoldStyle) async throws {
        let (opened, sink) = AsyncStream.makeStream(of: String.self)
        let provider = HomeAgentFoldRowProvider(style: style.rawValue) { peer, _ in sink.yield(peer) }
        var row = Self.rows()[0].1
        row.peerTitles = ["Sidebar alignment fix", "Nightly appcast rebuild", "First-click button audit"]
        let part = try #require(provider.part(row))
        guard case let .custom(custom) = part else { Issue.record("not a drawn row"); return }
        let payload = try #require(HomeAgentFoldRowProvider.payload(custom))
        #expect(payload.titles == row.peerTitles)
        let shape = try #require(style.pillShape)
        let pills = HomeAgentPills(payload, shape: shape, width: 900)
        #expect(pills.pills.map(\.title) == row.peerTitles)
        let ref = PartRef(messageId: "m1", partIndex: 0)
        // Between pills the click is not taken (the row folds as before).
        #expect(!provider.tapped(custom, ref: ref, at: CGPoint(x: 899, y: 1), width: 900))
        for pill in pills.pills {
            #expect(provider.tapped(custom, ref: ref, at: CGPoint(x: pill.rect.midX, y: pill.rect.midY), width: 900))
        }
        var got: [String] = []
        for await peer in opened {
            got.append(peer)
            if got.count == 3 { break }
        }
        #expect(got == ["a959", "a931", "a940"])
        // Stacked pills: the row grows with its agents; chips stay one row.
        let height = provider.measure(custom, maxWidth: 900).height
        #expect(shape == .chip ? height < 40 : height >= 3 * HomeAgentPills.pillHeight(shape))
    }

    @Test func theShippedProviderDrawsTheShippedPills() throws {
        let part = try #require(HomeAgentFoldRowProvider().part(Self.rows()[0].1))
        guard case let .custom(custom) = part else { Issue.record("not a drawn row"); return }
        let payload = try #require(HomeAgentFoldRowProvider.payload(custom))
        #expect(payload.style == 0)
        #expect(HomeAgentFoldStyle.drawing(payload) == nil)
        #expect(HomeAgentFoldRowProvider().measure(custom, maxWidth: 420).height == HomeAgentPills(payload, shape: .pill, width: 420).height)
    }
}
#endif
