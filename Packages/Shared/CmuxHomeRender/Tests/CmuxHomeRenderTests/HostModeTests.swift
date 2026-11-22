import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// A host with its own scroll view and compose field (the AppKit host).
@MainActor
@Suite struct HostModeTests {
    private func loaded(_ count: Int = 40, height: CGFloat = 800) -> (HomeController, [ScrollGeometrySpy]) {
        let c = Fixtures.controller(width: 628, height: height)
        let spy = ScrollGeometrySpy()
        c.onScrollGeometryChange = { spy.values.append($0) }
        c.setHostedField(CGRect(x: 51, y: height - 41, width: 526, height: 30))
        c.update(items: Fixtures.items(Fixtures.conversation(count)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        return (c, [spy])
    }

    @Test func hostScrollMovesRowsWithoutEchoingTheGeometry() throws {
        let (c, spies) = loaded()
        let spy = try #require(spies.first)
        let g = c.scrollGeometry
        #expect(g.offset == g.pinnedOffset, "an initial load pins to the newest row")
        let published = spy.values.count
        c.hostScrolled(to: g.offset - 300)
        #expect(c.scrollGeometry.offset == g.offset - 300)
        #expect(!c.isPinnedToNewest)
        #expect(spy.values.count == published, "a host scroll is not echoed back to the host")
        c.hostScrolled(to: g.pinnedOffset + 12)
        #expect(c.scrollGeometry.offset == g.pinnedOffset + 12, "an elastic overscroll is not clamped")
        #expect(c.isPinnedToNewest)
    }

    @Test func newRowsWhilePinnedKeepTheHostInStep() throws {
        let (c, spies) = loaded(40)
        let spy = try #require(spies.first)
        c.update(items: Fixtures.items(Fixtures.conversation(41)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let g = c.scrollGeometry
        #expect(g.offset == g.pinnedOffset, "a pinned transcript follows the new row")
        if let last = spy.values.last { #expect(last == g, "the last published geometry is the current one") }
    }

    @Test func theLastRowEndsAboveTheHostedField() throws {
        let (c, _) = loaded(10, height: 800)
        let last = c.scene.model.count - 1
        let bottom = c.scene.windowY(contentY: c.scene.layout.contentTop(last) + c.scene.model.rows[last].spec.height)
        let field = try #require(c.scene.hostedField)
        #expect(c.scene.compose.layer.isHidden)
        #expect(abs((field.minY - ComposeLayer.anchorAboveField) - c.scene.anchorY) < 0.001)
        #expect(bottom <= field.minY, "rows never sit under the field")
        c.setHostedField(CGRect(x: 51, y: 800 - 41 - 32, width: 526, height: 62))
        #expect(abs(c.scene.anchorY - (800 - 41 - 32 - ComposeLayer.anchorAboveField)) < 0.001)
    }

    @Test func aHostedSendFliesFromTheHostField() throws {
        let (c, _) = loaded(6)
        let messages = Fixtures.conversation(6)
        var emitted: [HomeIntent] = []
        c.onIntent = { emitted.append($0) }
        #expect(c.sendHosted(text: "   ", from: .zero) == nil, "blank drafts do not send")
        let field = try #require(c.scene.hostedField)
        let intent = try #require(c.sendHosted(text: "Ship it\n", from: field))
        #expect(emitted == [intent])
        guard case .sendMessage(_, let parts) = intent.op else { Issue.record("not a send"); return }
        #expect(parts == [.text("Ship it")])
        c.update(items: Fixtures.items(messages, pending: [PendingIntent(intent: intent)]), summary: Fixtures.summary(),
                 typing: [], hasOlder: false)
        #expect(!c.scene.morphs.isEmpty, "the send morph starts at the host field")
    }
}

@MainActor
final class ScrollGeometrySpy {
    var values: [HomeController.ScrollGeometry] = []
}
