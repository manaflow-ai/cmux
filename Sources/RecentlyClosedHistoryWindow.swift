import AppKit
import SwiftUI

@MainActor
final class RecentlyClosedHistoryWindowController: NSWindowController, NSWindowDelegate {
    static let shared = RecentlyClosedHistoryWindowController()

    private var preferredTabManager: TabManager?

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "menu.history.recentlyClosed", defaultValue: "Recently Closed")
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.recentlyClosedHistory")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(preferredTabManager: TabManager?) {
        self.preferredTabManager = preferredTabManager
        window?.contentView = NSHostingView(rootView: RecentlyClosedHistoryWindowView(
            preferredTabManager: preferredTabManager
        ))
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}

private struct RecentlyClosedHistoryWindowView: View {
    @ObservedObject private var store = ClosedItemHistoryStore.shared
    let preferredTabManager: TabManager?

    var body: some View {
        let snapshot = store.menuSnapshot()

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(String(localized: "menu.history.recentlyClosed", defaultValue: "Recently Closed"))
                    .font(.headline)
                Spacer()
                Button(String(localized: "menu.history.recentlyClosed.clearAll", defaultValue: "Clear All")) {
                    store.removeAll()
                }
                .disabled(snapshot.items.isEmpty)
            }

            if snapshot.items.isEmpty {
                Text(String(localized: "menu.history.recentlyClosed.empty", defaultValue: "No Recently Closed Items"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(snapshot.items) { item in
                            Button {
                                if AppDelegate.shared?.reopenClosedHistoryItem(
                                    id: item.id,
                                    preferredTabManager: preferredTabManager
                                ) != true {
                                    NSSound.beep()
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Text(item.title)
                                        .lineLimit(1)
                                    Spacer(minLength: 12)
                                    Text(item.detail)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 320)
    }
}
