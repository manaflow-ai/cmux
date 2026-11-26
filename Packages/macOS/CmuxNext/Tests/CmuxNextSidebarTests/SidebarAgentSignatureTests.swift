import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// `appearance.agentSignature`: each agent row's dot glyph, read once per session id from acpmux's
/// `session/signature` and drawn once per id, size and scale. Off, a row asks nothing and has no view for it.
@MainActor
@Suite(.serialized)
struct SidebarAgentSignatureTests {
    static let glyph = SidebarAgentSignature(seed: 0.37, variant: "Dust", accent: "#3D7BFF", drift: 1, dots: [
        .init(x: 0.31, y: 0.52, r: 0.11, phase: 0.4), .init(x: 0.62, y: 0.35, r: 0.08, phase: 0.1),
        .init(x: 0.55, y: 0.7, r: 0.1, phase: 0.8),
    ])

    /// Records each batch a store asks for and answers every id with ``glyph``.
    final class Asks {
        var batches: [[String]] = []
    }

    static func store(_ asks: Asks) -> SidebarAgentSignatures {
        SidebarAgentSignatures(fetch: { ids in
            asks.batches.append(ids)
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, glyph) })
        })
    }

    @Test func aReplyParsesIntoGlyphsAndTheRequestNamesTheIds() throws {
        let reply = Data(#"""
        {"jsonrpc":"2.0","id":1,"result":{"signatures":{"s1":{"seed":0.37,"variant":"Dust","accent":"#3D7BFF","drift":1.0,
        "dots":[{"x":0.31,"y":0.52,"r":0.11,"phase":0.4}]},"bad":{"variant":"x"}}}}
        """#.utf8)
        let glyphs = try #require(SidebarAgentSignature.signatures(reply: reply))
        #expect(glyphs.keys.sorted() == ["s1"])
        #expect(glyphs["s1"]?.dots == [.init(x: 0.31, y: 0.52, r: 0.11, phase: 0.4)])
        let rgb = try #require(glyphs["s1"]?.accentRGB)
        #expect(abs(rgb.red - 0x3D / 255.0) < 1e-9 && abs(rgb.green - 0x7B / 255.0) < 1e-9 && abs(rgb.blue - 1) < 1e-9)
        #expect(SidebarAgentSignature.signatures(reply: Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601}}"#.utf8)) == nil)

        let ids = (0..<600).map { "s\($0)" }
        let request = try #require(try JSONSerialization.jsonObject(with: SidebarAgentSignature.request(ids)) as? [String: Any])
        #expect(request["method"] as? String == "session/signature")
        let sent = (request["params"] as? [String: Any])?["sessionIds"] as? [String]
        #expect(sent?.count == SidebarAgentSignature.batchLimit)
    }

    @Test func offAsksNothing() {
        let asks = Asks()
        let store = Self.store(asks)
        #expect(store.glyph(for: "s1", enabled: false, row: nil) == nil)
        store.flush()
        #expect(store.requestCount == 0)
        #expect(asks.batches.isEmpty)
    }

    @Test func onAsksOnceForEveryRowOfATurnAndKeepsTheGlyphForever() async {
        let asks = Asks()
        let store = Self.store(asks)
        for id in ["s1", "s2", "s1", "s3", ""] { _ = store.glyph(for: id, enabled: true, row: nil) }
        _ = store.glyph(for: nil, enabled: true, row: nil)
        store.flush()
        #expect(store.requestCount == 1)
        for _ in 0..<200 where store.glyphs["s3"] == nil { await Task.yield() }
        #expect(asks.batches == [["s1", "s2", "s3"]])
        #expect(store.glyph(for: "s2", enabled: true, row: nil) == Self.glyph)
        store.flush()
        #expect(store.requestCount == 1, "a read id is never asked again")
    }

    @Test func aFailedRequestStaysQuiet() {
        let store = SidebarAgentSignatures(fetch: { _ in nil })
        _ = store.glyph(for: "s1", enabled: true, row: nil)
        store.flush()
        store.received(["s1"], nil)
        _ = store.glyph(for: "s1", enabled: true, row: nil)
        store.flush()
        #expect(store.requestCount == 1, "no second request inside the quiet time")
    }

    @Test func eachImageDrawsOncePerIdSizeAndScale() throws {
        let cache = SidebarAgentSignatureImage()
        let first = try #require(cache.image(id: "s1", glyph: Self.glyph, side: 12, scale: 2))
        #expect(cache.image(id: "s1", glyph: Self.glyph, side: 12, scale: 2) === first)
        #expect(cache.drawCount == 1)
        #expect(first.size == NSSize(width: 12, height: 12))
        let retina = try #require(cache.image(id: "s1", glyph: Self.glyph, side: 12, scale: 3))
        #expect(retina !== first)
        #expect(cache.drawCount == 2)
        #expect(cache.image(id: "s2", glyph: SidebarAgentSignature(seed: 0, variant: "", accent: "blue", drift: 1, dots: []),
                            side: 12, scale: 2) == nil, "no accent, no image")
    }

    private func row(_ ws: SidebarWorkspace, signatures: SidebarAgentSignatures) -> (WorkspaceRowView, NSWindow) {
        let row = SidebarRow(key: .workspace(ws.id), y: 0, height: 28, section: .pinned, group: nil, siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil)
        let view = WorkspaceRowView(key: row.key)
        view.agentSignatures = signatures
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 28), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
        view.configure(ws, row: row, badgeStyle: .corner)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    @Test func aRowDrawsNothingWhenOffAndTheGlyphBeforeItsTitleWhenOn() {
        var ws = SidebarWorkspace(id: WorkspaceID("ws-signature"), title: "Fix the build", lastActivity: Date())
        ws.agentSessionID = "signature-s1"
        DesignSettings.shared.agentSignature = false
        SidebarTunablesWatch.shared.changed()
        let asks = Asks()
        let signatures = Self.store(asks)
        let (off, offWindow) = row(ws, signatures: signatures)
        #expect(off.signatureMark == nil)
        #expect(!off.subviews.contains { $0 is DecorativeImageView && $0 !== off.agentMark && $0 !== off.mutedMark
            && $0 !== off.cloudMark && $0 !== off.usageWarningMark })
        let titleX = off.title.frame.minX
        signatures.flush()
        #expect(signatures.requestCount == 0, "off, the row asks nothing")
        offWindow.close()

        signatures.received(["signature-s1"], ["signature-s1": Self.glyph])
        DesignSettings.shared.agentSignature = true
        SidebarTunablesWatch.shared.changed()
        defer {
            DesignSettings.shared.agentSignature = false
            SidebarTunablesWatch.shared.changed()
        }
        let (on, onWindow) = row(ws, signatures: signatures)
        let mark = on.signatureMark
        #expect(mark?.isHidden == false)
        #expect(mark?.image != nil)
        #expect(mark?.frame.width == SidebarStyle.indicatorSize)
        #expect(on.title.frame.minX > titleX, "the title starts after the glyph")
        onWindow.close()
    }
}
