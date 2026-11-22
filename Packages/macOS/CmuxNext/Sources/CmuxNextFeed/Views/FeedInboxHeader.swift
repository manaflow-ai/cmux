import AppKit
import CmuxNextIcons
import SwiftUI

/// Connection tabs and compact inbox triage controls, driven by host callbacks.
struct FeedInboxHeader: View {
    /// Header glyphs sit beside 12 pt text.
    static let glyphSide = CGFloat.iconRowSize(forLabelPointSize: 12)
    @Binding var filter: FeedInboxFilter
    let hasUnread: Bool
    let canRefresh: Bool
    let canAddConnection: Bool
    let markRead: () -> Void
    let refresh: () -> Void
    let addConnection: () -> Void
    @Environment(\.feedColors) private var colors

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                connectionTab(.github, title: FeedStrings.github, icon: .brandGithub)
                connectionTab(.feed, title: FeedStrings.title, icon: .inbox)
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
            HStack(spacing: 10) {
                Icon(.search, size: Self.glyphSide).foregroundStyle(colors.tertiary)
                TextField(FeedStrings.filterInbox, text: $filter.query)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(colors.primary)
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
                .frame(width: 16).help(FeedStrings.filterInbox)
                Button(action: markRead) { Image(systemName: "checkmark.circle") }
                    .buttonStyle(.plain).disabled(!hasUnread).help(FeedStrings.markAllRead)
                if canRefresh {
                    Button(action: refresh) { Icon(.actionReload, size: Self.glyphSide) }
                        .buttonStyle(.plain).help(FeedStrings.refresh)
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
