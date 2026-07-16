import AppKit
import Foundation

/// The branch + directory block under a workspace row, covering the three
/// layouts `TabItemView` renders: vertical per-panel lines (optionally
/// stacking branch above directory) and the compact single-line summary.
final class SidebarWorkspaceCellBranchDirectorySection: NSView {
    private let row = SidebarWorkspaceCellStackFactory.horizontal(spacing: 3, alignment: .top)
    private let branchIcon = SidebarWorkspaceCellIconView()
    private let linesColumn = SidebarWorkspaceCellStackFactory.vertical(spacing: 1, alignment: .width)
    private let linesPool = SidebarWorkspaceCellRowPool<SidebarWorkspaceCellBranchLineView>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(branchIcon)
        row.addArrangedSubview(linesColumn)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// One rendered line per configure pass; compact modes emit a single line.
    private struct Line {
        var stackedBranch: String?
        var inlineBranch: String?
        var showsDot = false
        var directoryCandidates: [String] = []
    }

    func update(_ context: SidebarWorkspaceCellContext) {
        let settings = context.settings
        let workspace = context.workspace
        guard settings.visibleAuxiliaryDetails.showsBranchDirectory else {
            isHidden = true
            return
        }

        var lines: [Line] = []
        var showsIcon = false

        if settings.usesVerticalBranchLayout {
            guard !workspace.branchDirectoryLines.isEmpty else {
                isHidden = true
                return
            }
            showsIcon = settings.showsGitBranchIcon && workspace.branchLinesContainBranch
            for line in workspace.branchDirectoryLines {
                if settings.stacksBranchAndDirectory {
                    lines.append(Line(
                        stackedBranch: line.branch,
                        inlineBranch: nil,
                        showsDot: false,
                        directoryCandidates: line.directoryCandidates
                    ))
                } else {
                    lines.append(Line(
                        stackedBranch: nil,
                        inlineBranch: line.branch,
                        showsDot: line.branch != nil && !line.directoryCandidates.isEmpty,
                        directoryCandidates: line.directoryCandidates
                    ))
                }
            }
        } else if settings.stacksBranchAndDirectory,
                  workspace.compactGitBranchSummaryText != nil
                      || !workspace.compactDirectoryCandidates.isEmpty {
            showsIcon = settings.showsGitBranchIcon && workspace.compactGitBranchSummaryText != nil
            lines.append(Line(
                stackedBranch: workspace.compactGitBranchSummaryText,
                inlineBranch: nil,
                showsDot: false,
                directoryCandidates: workspace.compactDirectoryCandidates
            ))
        } else if !workspace.compactBranchDirectoryCandidates.isEmpty {
            showsIcon = settings.showsGitBranchIcon && workspace.compactGitBranchSummaryText != nil
            lines.append(Line(
                stackedBranch: nil,
                inlineBranch: nil,
                showsDot: false,
                directoryCandidates: workspace.compactBranchDirectoryCandidates
            ))
        } else {
            isHidden = true
            return
        }

        isHidden = false
        let style = context.style
        branchIcon.isHidden = !showsIcon
        if showsIcon {
            branchIcon.setSymbol(
                "arrow.triangle.branch",
                pointSize: style.fontSize(9),
                color: style.secondary(0.6)
            )
        }
        let views = linesPool.prepare(count: lines.count, in: linesColumn) {
            SidebarWorkspaceCellBranchLineView()
        }
        for (line, view) in zip(lines, views) {
            view.update(
                stackedBranch: line.stackedBranch,
                inlineBranch: line.inlineBranch,
                showsDot: line.showsDot,
                directoryCandidates: line.directoryCandidates,
                style: style
            )
        }
    }
}

/// One branch/directory line: either branch stacked above the directory, or
/// branch · directory inline.
final class SidebarWorkspaceCellBranchLineView: NSView {
    private let column = SidebarWorkspaceCellStackFactory.vertical(spacing: 1, alignment: .width)
    private let stackedBranchLabel = SidebarWorkspaceCellLabel()
    private let inlineRow = SidebarWorkspaceCellStackFactory.horizontal(spacing: 3)
    private let inlineBranchLabel = SidebarWorkspaceCellLabel()
    private let dotIcon = SidebarWorkspaceCellIconView()
    private let directoryLabel = SidebarWorkspaceCellDirectoryLabel()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        inlineBranchLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        inlineBranchLabel.setContentHuggingPriority(.required, for: .horizontal)
        inlineRow.addArrangedSubview(inlineBranchLabel)
        inlineRow.addArrangedSubview(dotIcon)
        inlineRow.addArrangedSubview(directoryLabel)
        column.addArrangedSubview(stackedBranchLabel)
        column.addArrangedSubview(inlineRow)
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(
        stackedBranch: String?,
        inlineBranch: String?,
        showsDot: Bool,
        directoryCandidates: [String],
        style: SidebarWorkspaceCellStyle
    ) {
        let font = SidebarWorkspaceCellFonts.monospaced(style.fontSize(10))
        let color = style.secondary(0.75)

        stackedBranchLabel.isHidden = stackedBranch == nil
        if let stackedBranch {
            stackedBranchLabel.font = font
            stackedBranchLabel.textColor = color
            stackedBranchLabel.stringValue = stackedBranch
        }

        inlineBranchLabel.isHidden = inlineBranch == nil
        if let inlineBranch {
            inlineBranchLabel.font = font
            inlineBranchLabel.textColor = color
            inlineBranchLabel.stringValue = inlineBranch
        }

        dotIcon.isHidden = !showsDot
        if showsDot {
            dotIcon.setSymbol("circle.fill", pointSize: style.fontSize(3), color: style.secondary(0.6))
        }

        directoryLabel.isHidden = directoryCandidates.isEmpty
        if !directoryCandidates.isEmpty {
            directoryLabel.update(candidates: directoryCandidates, font: font, color: color)
        }
        inlineRow.isHidden = inlineBranchLabel.isHidden && dotIcon.isHidden && directoryLabel.isHidden
    }
}
