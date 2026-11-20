import AppKit
@testable import CmuxNextHomeEngine
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-20 (a screenshot of the Chief Settings popover): the card hung off the "Chief"
/// pill's leading edge and ran over the transcript beside it. It opens centered under the pill,
/// as an `NSPopover` does.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeChiefSettingsPopoverPlacementTests {
    @Test func theCardOpensCenteredUnderThePill() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let pill = NSView(frame: NSRect(x: 410, y: 640, width: 80, height: 24))
        window.contentView?.addSubview(pill)
        window.orderFront(nil)
        let popover = HomeChiefSettingsPopover(content: HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory,
                                                                              source: UnreachableChief()))
        defer {
            popover.close()
            window.closeWithHomePopovers()
        }
        #expect(popover.show(relativeTo: pill, toggles: [pill]), "the popover did not show")
        let anchor = window.convertToScreen(pill.convert(pill.bounds, to: nil))
        let card = popover.cardFrame
        #expect(card.width == HomeChiefSettingsView.width)
        #expect(abs(card.midX - anchor.midX) <= 1, "card \(card) is not centered on the pill \(anchor)")
        #expect(card.maxY <= anchor.minY, "card \(card) covers the pill \(anchor)")
    }
}

private struct UnreachableChief: HomeChiefEngineSource {
    var isLocal: Bool { true }
    var place: String? { nil }
    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot { throw .localUnreachable }
    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot { throw .localUnreachable }
}
