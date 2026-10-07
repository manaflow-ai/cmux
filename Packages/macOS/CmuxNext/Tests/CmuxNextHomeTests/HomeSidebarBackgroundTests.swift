import AppKit
@testable import CmuxNextHome
import Testing

/// Lawrence (nxdog63-v2): "people area needs transparent bg". The Home list
/// column paints nothing of its own, so the window's material or background
/// image shows through it as it does behind the transcript.
@MainActor @Suite struct HomeSidebarBackgroundTests {
    @Test func theListColumnPaintsNoBackground() {
        let sidebar = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        sidebar.layoutSubtreeIfNeeded()
        #expect(!sidebar.isOpaque)
        #expect(sidebar.layer?.backgroundColor == nil, "the column fills itself")
        var view: NSView? = sidebar.subviews.first
        while let current = view {
            #expect(current.layer?.backgroundColor == nil, "\(type(of: current)) fills the column")
            view = current.subviews.first
        }
    }
}
