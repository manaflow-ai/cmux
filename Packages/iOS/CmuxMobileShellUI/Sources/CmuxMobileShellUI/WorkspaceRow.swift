import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Everything a workspace row draws, and nothing else.
///
/// ``WorkspaceRow`` reads only this value, so two equal contents render the
/// same pixels. The workspace table compares contents to decide whether a
/// relay update touches a row: fields the row never draws (surfaces,
/// simulators, directories) and sub-minute activity restamps cannot wake it.
struct WorkspaceRowContent: Equatable {
    let rpcWorkspaceID: String
    let name: String
    let isPinned: Bool
    let unreadState: MobileWorkspaceUnreadState
    let accentColorHex: String?
    /// The trailing label: a connection problem, or the activity time at the
    /// minute precision the row shows.
    let timestampText: String
    let description: String?
    let previewLine: String
    let changesChip: MobileWorkspaceChangesChip?
    /// Whether the changes chip is a button rather than a passive label.
    let opensChanges: Bool
    let isSelected: Bool
    let wrapWorkspaceTitles: Bool
    let previewLineLimit: Int
    let unreadIndicatorLeftShift: Double
    let unreadBadgeDiameter: Double

    init(
        workspace: MobileWorkspacePreview,
        connectionStatus: MobileMacConnectionStatus,
        isSelected: Bool,
        changesChip: MobileWorkspaceChangesChip?,
        opensChanges: Bool,
        wrapWorkspaceTitles: Bool,
        previewLineLimit: Int,
        unreadIndicatorLeftShift: Double,
        unreadBadgeDiameter: Double
    ) {
        let visibleChip = (changesChip?.filesChanged ?? 0) > 0 ? changesChip : nil
        rpcWorkspaceID = workspace.rpcWorkspaceID.rawValue
        name = workspace.name
        isPinned = workspace.isPinned
        unreadState = workspace.unreadState
        accentColorHex = workspace.customColorHex
        timestampText = workspace.timestampOrStatus(connectionStatus: connectionStatus)
        description = workspace.displayDescription
        previewLine = workspace.previewLine
        self.changesChip = visibleChip
        self.opensChanges = opensChanges && visibleChip != nil
        self.isSelected = isSelected
        self.wrapWorkspaceTitles = wrapWorkspaceTitles
        self.previewLineLimit = previewLineLimit
        self.unreadIndicatorLeftShift = unreadIndicatorLeftShift
        self.unreadBadgeDiameter = unreadBadgeDiameter
    }
}

struct WorkspaceRow: View {
    /// Daylight between the unread badge's trailing edge and the color rail.
    /// Internal (not private) so layout tests can assert the reservation math
    /// against the shipped constant.
    static let unreadDotRailVisualGap: CGFloat = 8
    private static let railTextVisualGap: CGFloat = 10
    private static let railVerticalInset: CGFloat = 5

    let content: WorkspaceRowContent
    /// Opens this workspace's changes without selecting the row. Ignored unless
    /// ``WorkspaceRowContent/opensChanges`` is set.
    let onOpenChanges: (@MainActor () -> Void)?

    init(content: WorkspaceRowContent, onOpenChanges: (@MainActor () -> Void)? = nil) {
        self.content = content
        self.onOpenChanges = onOpenChanges
    }

    /// `previewLineLimit` is the "Preview Lines" setting (1 or 2). Space is
    /// reserved so rows with short previews keep their neighbors' height.
    init(
        workspace: MobileWorkspacePreview,
        connectionStatus: MobileMacConnectionStatus,
        isSelected: Bool,
        changesChip: MobileWorkspaceChangesChip? = nil,
        onOpenChanges: (@MainActor () -> Void)? = nil,
        wrapWorkspaceTitles: Bool,
        previewLineLimit: Int = MobileDisplaySettings.defaultWorkspacePreviewLineCount,
        unreadIndicatorLeftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift,
        unreadBadgeDiameter: Double = MobileDisplaySettings.defaultUnreadBadgeDiameter
    ) {
        self.init(
            content: WorkspaceRowContent(
                workspace: workspace,
                connectionStatus: connectionStatus,
                isSelected: isSelected,
                changesChip: changesChip,
                opensChanges: onOpenChanges != nil,
                wrapWorkspaceTitles: wrapWorkspaceTitles,
                previewLineLimit: previewLineLimit,
                unreadIndicatorLeftShift: unreadIndicatorLeftShift,
                unreadBadgeDiameter: unreadBadgeDiameter
            ),
            onOpenChanges: onOpenChanges
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Unread is JUST this indicator (count badge, or dot against old
            // Macs), left of the workspace rail. The gutter is always present
            // (hidden when read) so read and unread rows line up. Center
            // alignment keeps it centered in the actual row height as
            // descriptions and previews wrap.
            WorkspaceUnreadDot(
                unread: content.unreadState,
                leftShift: content.unreadIndicatorLeftShift,
                diameter: content.unreadBadgeDiameter
            )

            Spacer()
                .frame(width: unreadDotRailLayoutGap)

            Color.clear
                .frame(width: WorkspaceColorRail.width)

            Spacer()
                .frame(width: Self.railTextVisualGap)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if content.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }

                    Text(content.name)
                        .font(.headline)
                        .foregroundStyle(content.isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(content.wrapWorkspaceTitles ? nil : 1)

                    Spacer(minLength: 8)

                    Text(content.timestampText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let description = content.description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2, reservesSpace: true)
                }

                HStack(alignment: .top, spacing: 8) {
                    Text(content.previewLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(content.previewLineLimit, reservesSpace: true)

                    if let changesChip = content.changesChip {
                        Spacer(minLength: 8)
                        changesChipView(changesChip)
                    }
                }
                if let taskStatus = workspace.taskStatus {
                    Label(taskStatus.label, systemImage: taskStatus.systemImage)
                        .font(.caption)
                        .foregroundStyle(taskStatus == .done ? .green : .secondary)
                        .accessibilityIdentifier("MobileWorkspaceCompletionStatus-\(workspace.id.rawValue)")
                }
            }
        }
        .overlay(alignment: .leading) {
            HStack(spacing: 0) {
                Spacer()
                    .frame(width: railLeadingOffset)

                WorkspaceColorRail(color: content.accentColorHex.flatMap { Color(hexString: $0) })
                    .padding(.vertical, Self.railVerticalInset)

                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, content.isSelected ? 10 : 0)
        .background {
            if content.isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
        .opacity(workspace.taskStatus == .done ? 0.6 : 1)
    }

    @ViewBuilder
    private func changesChipView(_ chip: MobileWorkspaceChangesChip) -> some View {
        if content.opensChanges, let onOpenChanges {
            Button(action: onOpenChanges) {
                WorkspaceChangesChipLabel(
                    chip: chip,
                    workspaceID: content.rpcWorkspaceID
                )
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        } else {
            WorkspaceChangesChipLabel(
                chip: chip,
                workspaceID: content.rpcWorkspaceID
            )
        }
    }

    private var unreadDotRailLayoutGap: CGFloat {
        // Reserving the badge's gutter overflow keeps the visual gap promise
        // for badge rows and one uniform rail column for every row.
        WorkspaceUnreadDot.layoutGap(
            afterGutterForDiameter: content.unreadBadgeDiameter,
            leftShift: content.unreadIndicatorLeftShift,
            visualGap: Self.unreadDotRailVisualGap
        )
    }

    private var railLeadingOffset: CGFloat {
        WorkspaceUnreadDot.gutterWidth + unreadDotRailLayoutGap
    }
}

struct WorkspaceColorRail: View {
    static let width: CGFloat = 3
    private static let cornerRadius: CGFloat = 1.5

    let color: Color?

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(color ?? Color.clear)
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .opacity(color == nil ? 0 : 0.95)
            .accessibilityHidden(true)
    }
}
