public import AppKit
public import CmuxSessionIndex
public import SwiftUI

/// A compact, single-line session row used inside the "Show more" popover list.
///
/// The row is a pure presentation leaf: it renders the agent icon, the
/// already-flattened display title, and a live-updating relative timestamp, and it
/// surfaces the host's drag payload and context menu through injected closures so it
/// reaches no app-side state directly. `displayTitle` and the agent presentation
/// values are resolved app-side: `SessionEntry.displayTitle` binds `String(localized:)`
/// against the host app bundle, and `SessionAgent.assetName`/`systemImageName` come
/// from the app-side presentation extension whose asset names live in the app's catalog.
///
/// Drag/menu seams: `dragItemProvider` builds the `NSItemProvider` the host registers
/// against its session drag registry; `menuContent` builds the right-click menu the
/// host shares with the full session row. Both are closures so the row carries no
/// reach into the app's drag registry or menu-action helpers.
public struct PopoverRow<MenuContent: View>: View, Equatable {
    private let entry: SessionEntry
    private let displayTitle: String
    private let agentAssetName: String?
    private let agentSystemImageName: String?
    private let onActivate: () -> Void
    private let dragItemProvider: @MainActor () -> NSItemProvider
    @ViewBuilder private let menuContent: () -> MenuContent

    @State private var isHovered: Bool = false

    /// Creates a popover session row.
    /// - Parameters:
    ///   - entry: The session this row represents.
    ///   - displayTitle: The app-resolved, localized title to show (single-line flattened internally).
    ///   - agentAssetName: The app-resolved asset-catalog icon name for the agent, or `nil`.
    ///   - agentSystemImageName: The app-resolved SF Symbol fallback name, or `nil`.
    ///   - onActivate: Invoked on double-click to open/resume the session.
    ///   - dragItemProvider: Builds the drag payload the host registers for this row.
    ///   - menuContent: Builds the shared right-click menu for this row.
    public init(
        entry: SessionEntry,
        displayTitle: String,
        agentAssetName: String?,
        agentSystemImageName: String?,
        onActivate: @escaping () -> Void,
        dragItemProvider: @escaping @MainActor () -> NSItemProvider,
        @ViewBuilder menuContent: @escaping () -> MenuContent
    ) {
        self.entry = entry
        self.displayTitle = displayTitle
        self.agentAssetName = agentAssetName
        self.agentSystemImageName = agentSystemImageName
        self.onActivate = onActivate
        self.dragItemProvider = dragItemProvider
        self.menuContent = menuContent
    }

    /// Equality compares only the entry; closures come from stable parent state and
    /// are not compared, matching the full session row's body-skip behavior.
    public static func == (lhs: PopoverRow<MenuContent>, rhs: PopoverRow<MenuContent>) -> Bool {
        lhs.entry == rhs.entry
    }

    /// Formats relative timestamps ("5m ago") for popover rows.
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
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary.opacity(0.7))
        .fixedSize()
    }

    public var body: some View {
        HStack(spacing: 6) {
            AgentIconImage(
                assetName: agentAssetName,
                systemImageName: agentSystemImageName,
                size: 12
            )
            // Flatten newlines so titles containing `<command-message>…\n…`
            // envelopes stay single-line; SwiftUI's `lineLimit(1)` doesn't
            // always constrain a Text that has hard line breaks in the
            // source string.
            Text(displayTitle.singleLineFlattened)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            modifiedText
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onActivate() }
        .onDrag { dragItemProvider() }
        .help(entry.cwdLabel ?? displayTitle)
        .contextMenu { menuContent() }
    }
}
