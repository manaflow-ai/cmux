public import AppKit
import CmuxNextDesign

/// How a docked workspace's view looks and stacks in the window frame (plans/cmux-next/docked-workspace-DESIGN.md V1,
/// V2): a Floating dock floats above the stage with a rounded rim and a soft shadow; every other view draws plainly.
extension NSView {
    /// Gives this docked workspace's view the Floating look, or takes it away. Idempotent: no layer write when
    /// nothing changes.
    public func applyDockedWorkspaceChrome(floating: Bool) {
        wantsLayer = true
        guard let layer else { return }
        let radius: CGFloat = floating ? Metrics.space3 : 0
        guard layer.cornerRadius != radius || (layer.shadowOpacity > 0) != floating else { return }
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.borderWidth = floating ? 1 : 0
        layer.borderColor = floating ? NSColor.separatorColor.cgColor : nil
        layer.shadowOpacity = floating ? 0.35 : 0
        layer.shadowRadius = floating ? 18 : 0
        layer.shadowOffset = CGSize(width: 0, height: -4)
        layer.shadowColor = NSColor.black.cgColor
        layer.masksToBounds = false
    }

    /// Puts the subviews in `front` (Floating docks) above every other subview, without detaching any view
    /// (`sortSubviews` keeps terminal surfaces and page windows in the window). No reorder when already in order.
    public func stackFloatingDocks(front: Set<ObjectIdentifier>) {
        let ranks = subviews.enumerated().map { (front.contains(ObjectIdentifier($1)) ? 1 : 0) * 100_000 + $0 }
        guard ranks != ranks.sorted() else { return }
        let table = StackingTable(ranks: Dictionary(uniqueKeysWithValues: zip(subviews.map(ObjectIdentifier.init), ranks)))
        withExtendedLifetime(table) {
            sortSubviews(compareStacking, context: Unmanaged.passUnretained(table).toOpaque())
        }
    }
}
