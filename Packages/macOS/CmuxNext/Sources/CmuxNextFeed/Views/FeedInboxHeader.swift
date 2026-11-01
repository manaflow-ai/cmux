import AppKit
import CmuxNextIcons
import SwiftUI
import CmuxNextDesign

/// Connection tabs and compact inbox triage controls, driven by host callbacks.
struct FeedInboxHeader: View {
    /// Header glyphs sit beside 12 pt text.
    static let glyphSide = CGFloat.iconRowSize(forLabelPointSize: 12)
    @Binding var filter: FeedInboxFilter
    let hasUnread: Bool
    let canRefresh: Bool
    let canAddConnection: Bool
    /// The host can send a reply to a report (the Feed page), so the Reports tab is offered.
    var showsReports = false
    let markRead: () -> Void
    let refresh: () -> Void
    let addConnection: () -> Void
    @Environment(\.feedColors) private var colors

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                connectionTab(.github, title: FeedStrings.github, icon: .brandGithub)
                connectionTab(.feed, title: FeedStrings.title, icon: .inbox)
                if showsReports { connectionTab(.reports, title: FeedStrings.reportsTitle, icon: .agentChat) }
                Spacer(minLength: 0)
                if canAddConnection {
                    Button(action: addConnection) {
                        Label {
                            Text(FeedStrings.addConnection)
                        } icon: {
                            Icon(.actionAdd, size: .iconRowSize(forLabelPointSize: 11.5))
                        }
                        .font(.system(size: 11.5))
                    }
                    .buttonStyle(.plain).foregroundStyle(colors.secondary)
                }
            }
            .padding(.horizontal, 10).frame(height: 43)
            FeedHairline()
            // The reports basket has its own list and reply box; the item search and triage stay with the items.
            if filter.connection != .reports { triage }
        }
    }

    private var triage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Icon(.search, size: Self.glyphSide).foregroundStyle(colors.tertiary)
                ThemedField(text: $filter.query, placeholder: FeedStrings.filterInbox, font: .systemFont(ofSize: 12),
                            height: 18, boxed: false)
                Menu {
                    Picker(FeedStrings.filterInbox, selection: $filter.category) {
                        Text(FeedStrings.allItems).tag(FeedInboxFilter.Category.all)
                        Text(FeedStrings.unread).tag(FeedInboxFilter.Category.unread)
                        Text(FeedStrings.needsYou).tag(FeedInboxFilter.Category.needsYou)
                        Text(FeedStrings.notices).tag(FeedInboxFilter.Category.notices)
                    }
                } label: {
                    // Menu labels render through AppKit, which keeps images but not canvases.
                    Image(nsImage: .icon(.filter, size: Self.glyphSide, style: filter.category == .all ? .line : .solid))
                        .renderingMode(.template)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 16).themedHelp(FeedStrings.filterInbox)
                .accessibilityLabel(FeedStrings.filterInbox).accessibilityIdentifier("cmux.feed.filter")
                Button(action: markRead) { Icon(.actionConfirm, size: Self.glyphSide) }
                    .buttonStyle(.plain).disabled(!hasUnread).themedHelp(FeedStrings.markAllRead)
                    .accessibilityLabel(FeedStrings.markAllRead).accessibilityIdentifier("cmux.feed.markAllRead")
                if canRefresh {
                    Button(action: refresh) { Icon(.actionReload, size: Self.glyphSide) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(FeedStrings.refresh).accessibilityIdentifier("cmux.feed.refresh")
                }
            }
            .font(.system(size: 12)).foregroundStyle(colors.secondary)
            .padding(.horizontal, 15).frame(height: 40)
            FeedHairline()
        }
    }

    private func connectionTab(_ connection: FeedInboxFilter.Connection, title: String, icon: IconName) -> some View {
        Button { filter.connection = connection } label: {
            FeedIconLabel(title, icon: icon, textSize: 11.5)
                .font(.system(size: 11.5, weight: filter.connection == connection ? .medium : .regular))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(filter.connection == connection ? colors.selection : .clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(filter.connection == connection ? colors.primary : colors.secondary)
    }
}
