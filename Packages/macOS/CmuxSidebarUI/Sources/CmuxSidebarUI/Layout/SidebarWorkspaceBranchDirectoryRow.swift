public import CmuxSidebar
public import CoreGraphics
public import SwiftUI

/// The git branch + working-directory cluster shown under a workspace row.
///
/// Renders one of three layouts driven by the sidebar settings: a multi-line
/// vertical branch layout, a single compact stacked branch-over-directory
/// layout, or a single inline branch · directory line. All inputs are
/// precomputed value snapshots (`branchDirectoryLines` and the compact
/// candidate arrays come from ``SidebarWorkspaceSnapshotBuilder/Snapshot``),
/// so the view holds no `@Observable` store reference and stays compliant with
/// the LazyVStack snapshot-boundary rule.
public struct SidebarWorkspaceBranchDirectoryRow: View {
    let branchDirectoryLines: [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine]
    let branchLinesContainBranch: Bool
    let compactGitBranchSummaryText: String?
    let compactDirectoryCandidates: [String]
    let compactBranchDirectoryCandidates: [String]
    let usesVerticalBranchLayout: Bool
    let stacksBranchAndDirectory: Bool
    let showsGitBranchIcon: Bool
    let secondaryColor: Color
    let iconColor: Color
    let fontScale: CGFloat

    /// Creates the branch + directory cluster.
    /// - Parameters:
    ///   - branchDirectoryLines: The vertical-layout branch/directory lines.
    ///   - branchLinesContainBranch: Whether any vertical line carries a branch.
    ///   - compactGitBranchSummaryText: The compact branch summary, or `nil`.
    ///   - compactDirectoryCandidates: Compact directory candidates (longest to
    ///     shortest) for the stacked compact layout.
    ///   - compactBranchDirectoryCandidates: Compact branch+directory candidates
    ///     for the inline compact layout.
    ///   - usesVerticalBranchLayout: Selects the multi-line vertical layout.
    ///   - stacksBranchAndDirectory: Stacks branch over directory in compact mode.
    ///   - showsGitBranchIcon: Whether to show the branch glyph.
    ///   - secondaryColor: Foreground color for branch/directory text.
    ///   - iconColor: Foreground color for the branch glyph and separator dot.
    ///   - fontScale: Multiplier applied to base font sizes.
    public init(
        branchDirectoryLines: [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine],
        branchLinesContainBranch: Bool,
        compactGitBranchSummaryText: String?,
        compactDirectoryCandidates: [String],
        compactBranchDirectoryCandidates: [String],
        usesVerticalBranchLayout: Bool,
        stacksBranchAndDirectory: Bool,
        showsGitBranchIcon: Bool,
        secondaryColor: Color,
        iconColor: Color,
        fontScale: CGFloat
    ) {
        self.branchDirectoryLines = branchDirectoryLines
        self.branchLinesContainBranch = branchLinesContainBranch
        self.compactGitBranchSummaryText = compactGitBranchSummaryText
        self.compactDirectoryCandidates = compactDirectoryCandidates
        self.compactBranchDirectoryCandidates = compactBranchDirectoryCandidates
        self.usesVerticalBranchLayout = usesVerticalBranchLayout
        self.stacksBranchAndDirectory = stacksBranchAndDirectory
        self.showsGitBranchIcon = showsGitBranchIcon
        self.secondaryColor = secondaryColor
        self.iconColor = iconColor
        self.fontScale = fontScale
    }

    private func scaledFontSize(_ baseSize: CGFloat) -> CGFloat {
        baseSize * fontScale
    }

    @ViewBuilder
    public var body: some View {
        if usesVerticalBranchLayout {
            verticalLayout
        } else if stacksBranchAndDirectory,
                  (compactGitBranchSummaryText != nil
                   || !compactDirectoryCandidates.isEmpty) {
            stackedCompactLayout
        } else if !compactBranchDirectoryCandidates.isEmpty {
            inlineCompactLayout
        }
    }

    @ViewBuilder
    private var verticalLayout: some View {
        if !branchDirectoryLines.isEmpty {
            HStack(alignment: .top, spacing: 3) {
                if showsGitBranchIcon, branchLinesContainBranch {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: scaledFontSize(9)))
                        .foregroundColor(iconColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(branchDirectoryLines.enumerated()), id: \.offset) { _, line in
                        if stacksBranchAndDirectory {
                            if let branch = line.branch {
                                Text(branch)
                                    .font(.system(size: scaledFontSize(10), design: .monospaced))
                                    .foregroundColor(secondaryColor)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            if !line.directoryCandidates.isEmpty {
                                SidebarDirectoryText(
                                    candidates: line.directoryCandidates,
                                    color: secondaryColor,
                                    fontScale: fontScale
                                )
                            }
                        } else {
                            HStack(spacing: 3) {
                                if let branch = line.branch {
                                    Text(branch)
                                        .font(.system(size: scaledFontSize(10), design: .monospaced))
                                        .foregroundColor(secondaryColor)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                if line.branch != nil, !line.directoryCandidates.isEmpty {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: scaledFontSize(3)))
                                        .foregroundColor(iconColor)
                                        .padding(.horizontal, 1)
                                }
                                if !line.directoryCandidates.isEmpty {
                                    SidebarDirectoryText(
                                        candidates: line.directoryCandidates,
                                        color: secondaryColor,
                                        fontScale: fontScale
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var stackedCompactLayout: some View {
        HStack(alignment: .top, spacing: 3) {
            if showsGitBranchIcon, compactGitBranchSummaryText != nil {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: scaledFontSize(9)))
                    .foregroundColor(iconColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                if let branchRow = compactGitBranchSummaryText {
                    Text(branchRow)
                        .font(.system(size: scaledFontSize(10), design: .monospaced))
                        .foregroundColor(secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if !compactDirectoryCandidates.isEmpty {
                    SidebarDirectoryText(
                        candidates: compactDirectoryCandidates,
                        color: secondaryColor,
                        fontScale: fontScale
                    )
                }
            }
        }
    }

    private var inlineCompactLayout: some View {
        HStack(spacing: 3) {
            if showsGitBranchIcon, compactGitBranchSummaryText != nil {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: scaledFontSize(9)))
                    .foregroundColor(iconColor)
            }
            SidebarDirectoryText(
                candidates: compactBranchDirectoryCandidates,
                color: secondaryColor,
                fontScale: fontScale
            )
        }
    }
}
