import AppKit
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import Foundation
import Testing

/// The host bar stays available while another app is frontmost, so its stop affordance must be
/// directly actionable and retain an accessible viewer title.
@MainActor @Suite(.serialized, .closesItsWindows)
struct MacScreenSharingBarTests {
    @Test func barExposesTitleAndOneClickStop() throws {
        let bar = MacScreenSharingBar()
        var stopCount = 0
        bar.update(title: "Studio is viewing this Mac") { stopCount += 1 }
        let button = try #require(bar.contentView.flatMap { findButton(in: $0, id: "macScreen.sharingBar.stop") })
        #expect(button.title == L.t("macScreen.indicator.stop", "Stop Sharing"))
        button.performClick(nil)
        #expect(stopCount == 1)
        bar.close()
    }

    @Test func barKeepsLongViewerNamesAccessible() throws {
        let bar = MacScreenSharingBar()
        let title = "Leo's MacBook Pro — a very long viewer name is still visible"
        bar.update(title: title) {}
        let root = try #require(bar.contentView)
        let label = try #require(findLabel(in: root, matching: title))
        #expect(label.stringValue == title)
        #expect(label.accessibilityLabel() == title)
        bar.close()
    }

    private func findButton(in view: NSView, id: String) -> NSButton? {
        if view.accessibilityIdentifier() == id, let button = view as? NSButton { return button }
        for child in view.subviews {
            if let match = findButton(in: child, id: id) { return match }
        }
        return nil
    }

    private func findLabel(in view: NSView, matching text: String) -> NSTextField? {
        if let label = view as? NSTextField, label.stringValue == text { return label }
        for child in view.subviews {
            if let match = findLabel(in: child, matching: text) { return match }
        }
        return nil
    }
}
