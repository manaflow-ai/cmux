#if DEBUG
import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// The Agent Messages Playground's header variants (user 2026-11-02, msg 19613: "i want playground in swift"):
/// every style turns a fold, an opened fold, a notes row and a note into one drawn row that keeps its style,
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
        var notes = HomeAgentMessageRow(group: group, kind: .notes(count: 2, peers: ["a933", "a936"], reason: .stopped(session: "Disconnected"),
                                                                    expanded: false))
        notes.peerStates = [.stopped, .stopped]
        notes.latest = "stopped without a report: its session is Disconnected"
        let note = HomeAgentMessageRow(group: group, kind: .note(peer: "a933", reason: .stopped(session: "Disconnected"),
                                                                 text: "stopped without a report: its session is Disconnected"))
        return [("fold", fold), ("open fold", open), ("notes", notes), ("note", note)]
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

    @Test func theShippedProviderStillDrawsTheShippedLine() throws {
        let part = try #require(HomeAgentFoldRowProvider().part(Self.rows()[0].1))
        guard case let .custom(custom) = part else { Issue.record("not a drawn row"); return }
        let payload = try #require(HomeAgentFoldRowProvider.payload(custom))
        #expect(payload.style == 0)
        #expect(HomeAgentFoldStyle.drawing(payload) == nil)
        #expect(HomeAgentFoldRowProvider().measure(custom, maxWidth: 420).height == HomeAgentFoldRowProvider.height)
    }
}
#endif
