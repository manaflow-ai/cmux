import SwiftUI

/// A file's folder and name on one line: the name always whole (truncated only when the
/// name alone is too wide), the folder in the width left over, head-truncated. When less
/// than `minimumFolderWidth` is left, the folder is not drawn at all, so it never shows as
/// a sliver or a lone glyph (round 4 review N8). Subviews: the folder, then the name
/// (`folderFirst`, a path) or the name, then the folder (`!folderFirst`, a file row). Give
/// the folder `.frame(minWidth: 0, alignment: .leading).clipped()` so a zero width hides it.
public struct FolderNameLayout: Layout {
    /// About three characters and the ellipsis of a footnote folder.
    public var minimumFolderWidth: CGFloat
    public var spacing: CGFloat
    public var folderFirst: Bool

    public init(folderFirst: Bool = true, minimumFolderWidth: CGFloat = 36, spacing: CGFloat = 0) {
        self.folderFirst = folderFirst
        self.minimumFolderWidth = minimumFolderWidth
        self.spacing = spacing
    }

    /// Widths of the folder and the name for the space offered.
    public static func widths(folderIdeal: CGFloat, nameIdeal: CGFloat, available: CGFloat?, minimumFolder: CGFloat, spacing: CGFloat) -> (folder: CGFloat, name: CGFloat) {
        guard let available else { return (folderIdeal, nameIdeal) }
        let name = min(nameIdeal, available)
        let left = available - name - spacing
        if folderIdeal <= left { return (folderIdeal, name) }
        return left >= minimumFolder ? (left, name) : (0, name)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let (folder, name) = folderFirst ? (subviews[0], subviews[1]) : (subviews[1], subviews[0])
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let w = Self.widths(folderIdeal: folder.sizeThatFits(.unspecified).width, nameIdeal: name.sizeThatFits(.unspecified).width,
                            available: available, minimumFolder: minimumFolderWidth, spacing: spacing)
        let gap = w.folder > 0 ? spacing : 0
        // The name's height at its width (it may wrap where its line limit allows).
        let nameHeight = name.sizeThatFits(ProposedViewSize(width: w.name, height: nil)).height
        let folderHeight = w.folder > 0 ? folder.sizeThatFits(ProposedViewSize(width: w.folder, height: nil)).height : 0
        return CGSize(width: w.folder + gap + w.name, height: max(folderHeight, nameHeight))
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (folder, name) = folderFirst ? (subviews[0], subviews[1]) : (subviews[1], subviews[0])
        let w = Self.widths(folderIdeal: folder.sizeThatFits(.unspecified).width, nameIdeal: name.sizeThatFits(.unspecified).width,
                            available: bounds.width, minimumFolder: minimumFolderWidth, spacing: spacing)
        let gap = w.folder > 0 ? spacing : 0
        let nameX = folderFirst ? bounds.minX + w.folder + gap : bounds.minX
        let folderX = folderFirst ? bounds.minX : bounds.minX + w.name + gap
        name.place(at: CGPoint(x: nameX, y: bounds.midY), anchor: .leading,
                   proposal: ProposedViewSize(width: w.name, height: bounds.height))
        folder.place(at: CGPoint(x: folderX, y: bounds.midY), anchor: .leading,
                     proposal: ProposedViewSize(width: w.folder, height: bounds.height))
    }
}
