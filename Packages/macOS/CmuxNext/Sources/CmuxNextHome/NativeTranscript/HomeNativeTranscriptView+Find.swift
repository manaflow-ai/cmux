public import AppKit
public import CmuxNextDesign

/// Find in this chat (not built yet: no find bar).
extension HomeNativeTranscriptView {
    /// The first Home transcript in `view` or under it.
    public static func first(in view: NSView) -> HomeNativeTranscriptView? {
        var stack = [view]
        while let next = stack.popLast() {
            if let home = next as? HomeNativeTranscriptView { return home }
            stack.append(contentsOf: next.subviews)
        }
        return nil
    }
    public var findBar: FindPillView? { findPill }
    public func showFind(text: String? = nil, takeFocus: Bool) {}
    public func stepFind(forward: Bool, takeFocus: Bool) {}
    public func hideFind(restoringFocus: Bool) {}
    func findRowsChanged() {}
    func layoutFind() {}
}
