public import AppKit
public import CmuxSessionIndex
public import SwiftUI

/// The full-width session row shown in the main session-index list.
///
/// The row is a pure presentation leaf: it renders the agent icon, the
/// already-resolved display title, and a live-updating relative timestamp, and it
/// surfaces the host's drag payload, context menu, and transcript-preview popover
/// through injected closures/builders so it reaches no app-side state directly.
///
/// App-resolved seams (mirroring ``PopoverRow``): `displayTitle` and the agent
/// presentation values are resolved app-side. `SessionEntry.displayTitle` binds
/// `String(localized:)` against the host app bundle, and
/// `SessionAgent.assetName`/`systemImageName` come from the app-side presentation
/// extension whose asset names live in the app's catalog. The hover/tooltip
/// `helpText` is composed app-side (it depends on the app's absolute-time
/// `DateFormatter`) and passed in whole.
///
/// Closure/builder seams: `dragItemProvider` builds the `NSItemProvider` the host
/// registers against its session drag registry; `menuContent` builds the
/// right-click menu the host shares with the popover row; `previewHost` builds the
/// app-side transcript-preview popover host (an AppKit `NSViewRepresentable`), shown
/// as a background only while `isPreviewPresented` is true; `onPreviewPresentationChange`
/// reports double-tap presentation requests back to the host. All are closures so the
/// row carries no reach into the app's drag registry, menu-action helpers, or popover
/// host. The live relative timestamp reuses the package's ``RelativeTimestampSchedule``.
public struct SessionRow<PreviewHost: View, MenuContent: View>: View, Equatable {
    private let entry: SessionEntry
    private let displayTitle: String
    private let agentAssetName: String?
    private let agentSystemImageName: String?
    private let helpText: String
    private let isPreviewPresented: Bool
    private let onPreviewPresentationChange: (Bool) -> Void
    private let dragItemProvider: @MainActor () -> NSItemProvider
    @ViewBuilder private let previewHost: () -> PreviewHost
    @ViewBuilder private let menuContent: () -> MenuContent

    @State private var isHovered: Bool = false

    /// Creates a full session row.
    /// - Parameters:
    ///   - entry: The session this row represents.
    ///   - displayTitle: The app-resolved, localized title to show.
    ///   - agentAssetName: The app-resolved asset-catalog icon name for the agent, or `nil`.
    ///   - agentSystemImageName: The app-resolved SF Symbol fallback name, or `nil`.
    ///   - helpText: The app-composed multi-line tooltip (title, optional cwd, absolute time).
    ///   - isPreviewPresented: Whether the transcript preview popover is currently shown.
    ///   - onPreviewPresentationChange: Reports a request to present/dismiss the preview popover.
    ///   - dragItemProvider: Builds the drag payload the host registers for this row.
    ///   - previewHost: Builds the app-side transcript-preview popover host.
    ///   - menuContent: Builds the shared right-click menu for this row.
    public init(
        entry: SessionEntry,
        displayTitle: String,
        agentAssetName: String?,
        agentSystemImageName: String?,
        helpText: String,
        isPreviewPresented: Bool,
        onPreviewPresentationChange: @escaping (Bool) -> Void,
        dragItemProvider: @escaping @MainActor () -> NSItemProvider,
        @ViewBuilder previewHost: @escaping () -> PreviewHost,
        @ViewBuilder menuContent: @escaping () -> MenuContent
    ) {
        self.entry = entry
        self.displayTitle = displayTitle
        self.agentAssetName = agentAssetName
        self.agentSystemImageName = agentSystemImageName
        self.helpText = helpText
        self.isPreviewPresented = isPreviewPresented
        self.onPreviewPresentationChange = onPreviewPresentationChange
        self.dragItemProvider = dragItemProvider
        self.previewHost = previewHost
        self.menuContent = menuContent
    }

    /// Skip body re-eval during scroll when the entry and preview state are unchanged.
    /// The closures aren't compared (they come from stable parent state).
    public static func == (lhs: SessionRow<PreviewHost, MenuContent>, rhs: SessionRow<PreviewHost, MenuContent>) -> Bool {
        lhs.entry == rhs.entry &&
            lhs.isPreviewPresented == rhs.isPreviewPresented
    }

    /// Formats relative timestamps ("5m ago") for session rows.
    static var relativeFormatter: RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }

    @ViewBuilder
    private var modifiedText: some View {
        TimelineView(RelativeTimestampSchedule(modified: entry.modified)) { context in
            Text(Self.relativeFormatter.localizedString(for: entry.modified, relativeTo: context.date))
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.secondary.opacity(0.65))
        .fixedSize()
    }

    public var body: some View {
        HStack(spacing: 6) {
            AgentIconImage(
                assetName: agentAssetName,
                systemImageName: agentSystemImageName,
                size: 12
            )
            Text(displayTitle)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            modifiedText
        }
        .padding(.leading, 32)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowBackground)
        .background(previewPopoverHost)
        .onHover { isHovered = $0 }
        .help(helpText)
        .onTapGesture(count: 2) {
            onPreviewPresentationChange(true)
        }
        .onDrag {
            dragItemProvider()
        } preview: {
            HStack(spacing: 6) {
                AgentIconImage(
                    assetName: agentAssetName,
                    systemImageName: agentSystemImageName,
                    size: 12
                )
                Text(displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .contextMenu {
            menuContent()
        }
    }

    @ViewBuilder
    private var previewPopoverHost: some View {
        if isPreviewPresented {
            previewHost()
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(rowBackgroundColor)
            .padding(.horizontal, 6)
    }

    private var rowBackgroundColor: Color {
        if isHovered {
            return Color.primary.opacity(0.05)
        }
        if isPreviewPresented {
            return Color.primary.opacity(0.07)
        }
        return Color.clear
    }
}
