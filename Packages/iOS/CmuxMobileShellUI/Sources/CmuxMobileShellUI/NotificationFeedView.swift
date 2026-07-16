import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Value-driven notification feed used by both the live screen and preview route.
struct NotificationFeedView: View {
    let sections: [NotificationFeedSection]
    let isRefreshing: Bool
    let hasLoaded: Bool
    let showsIntro: Bool
    let pushEnabled: Bool
    let actions: NotificationFeedActions

    var body: some View {
        TimelineView(.everyMinute) { context in
            if !hasLoaded && isRefreshing {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(now: context.date)
            }
        }
        .navigationTitle(L10n.string("mobile.notifications.title", defaultValue: "Notifications"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func list(now: Date) -> some View {
        List {
            if showsIntro {
                introCard
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)
            }
            if sections.isEmpty {
                ContentUnavailableView(
                    L10n.string("mobile.notifications.empty.title", defaultValue: "No notifications yet"),
                    systemImage: "bell",
                    description: Text(L10n.string(
                        "mobile.notifications.empty.description",
                        defaultValue: "When an agent finishes work or needs your input on your Mac, it shows up here. Try cmux notify from any workspace."
                    ))
                )
                .frame(maxWidth: .infinity, minHeight: 360)
                .listRowSeparator(.hidden)
            } else {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            NotificationFeedRow(
                                item: item,
                                timeLabel: NotificationFeedTimeLabelPolicy(now: now).label(for: item.createdAt),
                                actions: NotificationFeedRowActions(
                                    open: { actions.open(item) },
                                    toggleRead: { actions.toggleRead(item) },
                                    remove: { actions.remove(item) }
                                )
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text(sectionTitle(section.day))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 16)
        .refreshable { await actions.refresh() }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(L10n.string(
                    "mobile.notifications.intro.body",
                    defaultValue: "Agent updates from your Mac stay here so you can catch up anytime."
                ))
                .font(.footnote)
                Spacer(minLength: 4)
                Button(action: actions.dismissIntro) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string(
                    "mobile.notifications.intro.dismiss",
                    defaultValue: "Dismiss"
                ))
            }
            if !pushEnabled {
                Text(L10n.string(
                    "mobile.notifications.intro.pushBody",
                    defaultValue: "Enable push notifications to hear about new updates right away."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                Button(
                    L10n.string(
                        "mobile.notifications.intro.enablePush",
                        defaultValue: "Enable push notifications"
                    ),
                    action: actions.enablePush
                )
                .font(.footnote.weight(.semibold))
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
        }
        .accessibilityIdentifier("MobileNotificationFeedIntroCard")
    }

    private func sectionTitle(_ day: NotificationFeedDay) -> String {
        switch day {
        case .today:
            L10n.string("mobile.notifications.section.today", defaultValue: "Today")
        case .yesterday:
            L10n.string("mobile.notifications.section.yesterday", defaultValue: "Yesterday")
        case .older(let date):
            date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }
}
