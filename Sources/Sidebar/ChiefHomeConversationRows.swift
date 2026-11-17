import AppKit
import CmuxFoundation
import CmuxHomeCore
import MessagesLabSidebar
import SwiftUI

/// The compact conversation stack revealed below Home in the workspace list.
///
/// The full MessagesLab list remains available when Home is selected. This
/// disclosure is intentionally smaller: it keeps the normal workspace rows in
/// view while making Chief threads discoverable and draggable from the same
/// sidebar surface.
struct ChiefHomeConversationRowsRepresentable: NSViewRepresentable {
    let home: ChiefHomeView
    let accent: CmuxAccentColor

    func makeNSView(context: Context) -> ChiefHomeConversationRowsView {
        let view = ChiefHomeConversationRowsView(home: home, accent: accent)
        view.apply(accent: accent)
        return view
    }

    func updateNSView(_ view: ChiefHomeConversationRowsView, context: Context) {
        view.apply(accent: accent)
    }

    static func dismantleNSView(_ view: ChiefHomeConversationRowsView, coordinator: ()) {
        view.stopObserving()
    }
}

/// AppKit-hosted SwiftUI rows for Home's collapsed disclosure.
@MainActor
final class ChiefHomeConversationRowsView: NSHostingView<ChiefHomeConversationRows> {
    private let home: ChiefHomeView

    init(home: ChiefHomeView, accent: CmuxAccentColor) {
        self.home = home
        super.init(rootView: ChiefHomeConversationRows(home: home, accent: accent))
        setAccessibilityIdentifier("ChiefHomeConversationRows")
    }

    @available(*, unavailable)
    required init(rootView: ChiefHomeConversationRows) {
        fatalError("init(rootView:) has not been implemented")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(accent: CmuxAccentColor) {
        rootView = ChiefHomeConversationRows(home: home, accent: accent)
    }

    func stopObserving() {
        // The callback is owned by Home and must not retain this hosting view.
        home.onRowsChanged = nil
    }
}

/// A compact, sequential Home conversation stack with native pane drags.
struct ChiefHomeConversationRows: View {
    let home: ChiefHomeView
    let accent: CmuxAccentColor

    @State private var entries: [CmuxSidebarEntry] = []
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 2) {
                ForEach(entries, id: \.id) { entry in
                    row(entry)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .background(Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.18 : 0.5))
        .onAppear {
            entries = home.list.list.entries
            home.onRowsChanged = { updated in
                entries = updated
            }
        }
        .onDisappear {
            home.onRowsChanged = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(ChiefStrings.conversationsList))
    }

    private func row(_ entry: CmuxSidebarEntry) -> some View {
        let selected = home.selected.rawValue == entry.id
        return Button {
            home.select(ConversationID(entry.id))
        } label: {
            HStack(spacing: 8) {
                avatar(entry)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(entry.preview)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if entry.unreadCount > 0 {
                    Circle()
                        .fill(accent.color)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(accent.color.opacity(colorScheme == .dark ? 0.18 : 0.12))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(entry.title))
        .accessibilityValue(Text(entry.preview))
        .accessibilityIdentifier("ChiefHomeConversationRow.\(entry.id)")
        .onDrag {
            guard let registry = AppDelegate.shared?.tabDragTransferRegistry,
                  let provider = ChiefPaneDragPayload(conversationID: ConversationID(entry.id))
                      .provider(with: registry) else {
                return NSItemProvider()
            }
            return provider
        }
    }

    @ViewBuilder
    private func avatar(_ entry: CmuxSidebarEntry) -> some View {
        let initials = entry.people.first?.initials ?? String(entry.title.prefix(1)).uppercased()
        Text(initials)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Color(nsColor: .controlBackgroundColor), in: Circle())
            .overlay(Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
