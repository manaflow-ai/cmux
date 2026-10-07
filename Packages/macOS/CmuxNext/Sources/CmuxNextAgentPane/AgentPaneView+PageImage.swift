public import AppKit

extension AgentPaneView {
    /// An image of the page as shown (the next launch draws it until this
    /// page paints again).
    public func pageImage() async -> NSImage? {
        await snapshotPage()
    }
}
