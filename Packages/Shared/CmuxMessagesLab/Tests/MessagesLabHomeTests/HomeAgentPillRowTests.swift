import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// The shipped agents row (user 2026-11-03, msg 19960): one pill per agent, ChatGPT's look, with the
/// agent's title and its state, as tall as its pills, drawn with ink in each pill.
@MainActor @Suite struct HomeAgentPillRowTests {
    static func row() -> HomeAgentMessageRow {
        var row = HomeAgentMessageRow(group: "0123456789abcdef", kind: .fold(count: 5, peers: ["a959", "a931", "a933"], expanded: false))
        row.peerStates = [.reported, .told, .stopped]
        row.peerTitles = ["Sidebar alignment fix", "Nightly appcast rebuild", "a933"]
        return row
    }

    @Test func theShippedRowDrawsOnePillPerAgentWithItsTitleAndState() throws {
        let provider = HomeAgentFoldRowProvider()
        let part = try #require(provider.part(Self.row()))
        guard case let .custom(custom) = part else { Issue.record("not a drawn row"); return }
        let payload = try #require(HomeAgentFoldRowProvider.payload(custom))
        let pills = HomeAgentPills(payload, shape: .pill, width: 420)
        #expect(pills.pills.map(\.title) == Self.row().peerTitles)
        #expect(pills.pills.map(\.state) == ["reported", "told", "stopped"])
        let height = provider.measure(custom, maxWidth: 420).height
        #expect(height == pills.height)
        #expect(height >= 3 * HomeAgentPills.pillHeight(.pill))

        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let h = Int(height.rounded(.up))
        let ctx = try #require(CGContext(data: nil, width: 420, height: h, bitsPerComponent: 8, bytesPerRow: 420 * 4,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        provider.drawRow(custom, in: ctx, rect: CGRect(x: 0, y: 0, width: 420, height: height),
                         context: CustomRowDrawContext(outgoing: false, isDark: false, elevated: false))
        let data = try #require(ctx.makeImage()?.dataProvider?.data as Data?)
        let bytes = [UInt8](data)
        // Each pill's middle line has ink (the pill's fill), so no pill is left blank.
        for pill in pills.pills {
            let y = Int(pill.rect.midY)
            let line = bytes[(y * 420 * 4)..<((y + 1) * 420 * 4)]
            #expect(line.contains { $0 > 0 }, "\(pill.peer): its pill drew nothing")
        }
    }
}
