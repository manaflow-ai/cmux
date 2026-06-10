import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Branch, directory, pull request, port metadata display
extension TabItemView {
    // Builds the joined "branch · directory" candidates list for inline mode.
    // Each entry pairs the (fixed) git summary with one entry from the
    // directory candidates list, so ViewThatFits can choose how aggressively to
    // shorten the directory portion as the row width changes.
    func compactBranchDirectoryCandidatesList(
        gitSummary: String?,
        directoryCandidates: [String]
    ) -> [String] {
        if directoryCandidates.isEmpty {
            return gitSummary.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        }
        guard let gitSummary, !gitSummary.isEmpty else { return directoryCandidates }
        return directoryCandidates.map { "\(gitSummary) · \($0)" }
    }

    func gitBranchSummaryText(orderedPanelIds: [UUID]) -> String? {
        let lines = gitBranchSummaryLines(orderedPanelIds: orderedPanelIds)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " | ")
    }

    private func gitBranchSummaryLines(orderedPanelIds: [UUID]) -> [String] {
        tab.sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds).map { branch in
            "\(branch.branch)\(branch.isDirty ? "*" : "")"
        }
    }

    func verticalBranchDirectoryLines(orderedPanelIds: [UUID]) -> [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine] {
        let entries = tab.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        let home = SidebarPathFormatter.homeDirectoryPath
        let useViewportAwarePath = sidebarUsesLastSegmentPath
        return entries.compactMap { entry in
            let branchText: String? = {
                guard sidebarShowGitBranch, let branch = entry.branch else { return nil }
                return "\(branch)\(entry.isDirty ? "*" : "")"
            }()

            let directoryCandidates: [String] = {
                guard let directory = entry.directory else { return [] }
                if useViewportAwarePath {
                    return SidebarPathFormatter.pathCandidates(directory, homeDirectoryPath: home)
                }
                let shortened = SidebarPathFormatter.shortenedPath(directory, homeDirectoryPath: home)
                return shortened.isEmpty ? [] : [shortened]
            }()

            if branchText == nil && directoryCandidates.isEmpty {
                return nil
            }
            return SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine(
                branch: branchText,
                directoryCandidates: directoryCandidates
            )
        }
    }

    // Candidates for the inline-mode directory line, longest → shortest. When
    // viewport-aware truncation is off, returns a single element with each
    // panel directory shortened via `~/`. When on, walks per-path candidate
    // indices, bumping the rightmost path that can still shrink at each step.
    // Each emitted candidate differs from the previous by exactly one path
    // collapsing one level, so ViewThatFits sees a strictly monotone gradient
    // (`full|full`, `full|mid`, `full|leaf`, `mid|leaf`, `leaf|leaf`) — later
    // panels shrink before earlier ones, preserving the leading workspace dir
    // as long as the row width allows.
    func compactDirectoryCandidatesList(orderedPanelIds: [UUID]) -> [String] {
        let home = SidebarPathFormatter.homeDirectoryPath
        let directories = tab.sidebarDirectoriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        guard !directories.isEmpty else { return [] }

        if !sidebarUsesLastSegmentPath {
            let joined = directories
                .map { SidebarPathFormatter.shortenedPath($0, homeDirectoryPath: home) }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            return joined.isEmpty ? [] : [joined]
        }

        let perDirectoryCandidates: [[String]] = directories
            .map { SidebarPathFormatter.pathCandidates($0, homeDirectoryPath: home) }
            .filter { !$0.isEmpty }
        guard !perDirectoryCandidates.isEmpty else { return [] }

        var indices = Array(repeating: 0, count: perDirectoryCandidates.count)
        var result: [String] = []
        while true {
            let pieces = zip(indices, perDirectoryCandidates).map { idx, candidates in
                candidates[idx]
            }
            let joined = pieces.joined(separator: " | ")
            if !joined.isEmpty, result.last != joined {
                result.append(joined)
            }
            guard let bumpIdx = indices.indices.last(where: { indices[$0] < perDirectoryCandidates[$0].count - 1 }) else {
                break
            }
            indices[bumpIdx] += 1
        }
        return result
    }

    func pullRequestDisplays(orderedPanelIds: [UUID]) -> [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] {
        tab.sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds).map { pullRequest in
            SidebarWorkspaceSnapshotBuilder.PullRequestDisplay(
                id: "\(pullRequest.label.lowercased())#\(pullRequest.number)|\(pullRequest.url.absoluteString)",
                number: pullRequest.number,
                label: pullRequest.label,
                url: pullRequest.url,
                status: pullRequest.status,
                isStale: pullRequest.isStale
            )
        }
    }

    var pullRequestForegroundColor: Color {
        isActive ? activeSecondaryColor(0.75) : .secondary
    }

    func openPullRequestLink(_ url: URL) {
        updateSelection()
        if openSidebarPullRequestLinksInCmuxBrowser {
            if tabManager.openBrowser(
                inWorkspace: tab.id,
                url: url,
                preferSplitRight: true,
                insertAtEnd: true
            ) == nil {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openPortLink(_ port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        updateSelection()
        if openSidebarPortLinksInCmuxBrowser {
            if tabManager.openBrowser(
                inWorkspace: tab.id,
                url: url,
                preferSplitRight: true,
                insertAtEnd: true
            ) == nil {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    func pullRequestStatusLabel(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open: return String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged: return String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed: return String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
    }

    func logLevelIcon(_ level: SidebarLogLevel) -> String {
        switch level {
        case .info: return "circle.fill"
        case .progress: return "arrowtriangle.right.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    func logLevelColor(_ level: SidebarLogLevel, isActive: Bool) -> Color {
        if isActive {
            switch level {
            case .info:
                return activeSecondaryColor(0.5)
            case .progress:
                return activeSecondaryColor(0.8)
            case .success:
                return activeSecondaryColor(0.9)
            case .warning:
                return activeSecondaryColor(0.9)
            case .error:
                return activeSecondaryColor(0.9)
            }
        }
        switch level {
        case .info: return .secondary
        case .progress: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func shortenPath(_ path: String, home: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        if trimmed == home {
            return "~"
        }
        if trimmed.hasPrefix(home + "/") {
            return "~" + trimmed.dropFirst(home.count)
        }
        return trimmed
    }

    struct PullRequestStatusIcon: View {
        let status: SidebarPullRequestStatus
        let color: Color
        var fontScale: CGFloat = 1
        private static let closedFrameSize: CGFloat = 12
        private static let customFrameSize: CGFloat = 13

        private var closedFrameSize: CGFloat {
            Self.closedFrameSize * fontScale
        }

        private var customFrameSize: CGFloat {
            Self.customFrameSize * fontScale
        }

        var body: some View {
            switch status {
            case .open:
                PullRequestOpenIcon(color: color)
                    .scaleEffect(fontScale)
                    .frame(width: customFrameSize, height: customFrameSize)
            case .merged:
                PullRequestMergedIcon(color: color)
                    .scaleEffect(fontScale)
                    .frame(width: customFrameSize, height: customFrameSize)
            case .closed:
                Image(systemName: "xmark.circle")
                    .font(.system(size: 7 * fontScale, weight: .regular))
                    .foregroundColor(color)
                    .frame(width: closedFrameSize, height: closedFrameSize)
            }
        }
    }

    private struct PullRequestOpenIcon: View {
        let color: Color
        static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        private static let nodeDiameter: CGFloat = 3.0
        private static let frameSize: CGFloat = 13

        var body: some View {
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 3.0, y: 4.8))
                    path.addLine(to: CGPoint(x: 3.0, y: 9.2))

                    path.move(to: CGPoint(x: 4.8, y: 3.0))
                    path.addLine(to: CGPoint(x: 9.4, y: 3.0))
                    path.addLine(to: CGPoint(x: 11.0, y: 4.6))
                    path.addLine(to: CGPoint(x: 11.0, y: 9.2))
                }
                .stroke(color, style: Self.stroke)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 3.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 11.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 11.0, y: 11.0)
            }
            .frame(width: Self.frameSize, height: Self.frameSize)
        }
    }

    private struct PullRequestMergedIcon: View {
        let color: Color
        static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        private static let nodeDiameter: CGFloat = 3.0
        private static let frameSize: CGFloat = 13

        var body: some View {
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 4.6, y: 4.6))
                    path.addLine(to: CGPoint(x: 7.1, y: 7.0))
                    path.addLine(to: CGPoint(x: 9.2, y: 7.0))

                    path.move(to: CGPoint(x: 4.6, y: 9.4))
                    path.addLine(to: CGPoint(x: 7.1, y: 7.0))
                }
                .stroke(color, style: Self.stroke)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 3.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 11.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 11.0, y: 7.0)
            }
            .frame(width: Self.frameSize, height: Self.frameSize)
        }
    }

}
