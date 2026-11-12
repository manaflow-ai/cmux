#if os(iOS) && DEBUG
import CmuxMobileSupport
import Foundation
import SwiftUI

/// A frozen range keeps a catalog refresh from changing an open replay.
struct MobileWhatsNewReplay: Identifiable {
    let id = UUID()
    let pages: [MobileWhatsNewPage]

    init?(pages: [MobileWhatsNewPage], firstID: String, lastID: String) {
        guard let first = pages.firstIndex(where: { $0.listID == firstID }),
              let last = pages.firstIndex(where: { $0.listID == lastID }) else { return nil }
        self.pages = Array(pages[min(first, last)...max(first, last)])
    }
}

struct MobileWhatsNewDebugView: View {
    let pages: [MobileWhatsNewPage]
    let allowedWebHosts: Set<String>
    @State private var firstID: String
    @State private var lastID: String
    @State private var replay: MobileWhatsNewReplay?

    init(pages: [MobileWhatsNewPage], allowedWebHosts: Set<String>) {
        self.pages = pages
        self.allowedWebHosts = allowedWebHosts
        _firstID = State(initialValue: pages.first?.listID ?? "")
        _lastID = State(initialValue: pages.last?.listID ?? "")
    }

    private var selection: MobileWhatsNewReplay? {
        MobileWhatsNewReplay(pages: pages, firstID: firstID, lastID: lastID)
    }

    var body: some View {
        Form {
            if pages.isEmpty {
                Text(L10n.string("mobile.whatsNew.debug.empty", defaultValue: "No updates available"))
            } else {
                Section {
                    Picker(
                        L10n.string("mobile.whatsNew.debug.first", defaultValue: "First Update"),
                        selection: $firstID
                    ) {
                        ForEach(pages, id: \.listID) { page in
                            Text(page.id).tag(page.listID)
                        }
                    }
                    .accessibilityIdentifier("MobileWhatsNewReplayFirst")

                    Picker(
                        L10n.string("mobile.whatsNew.debug.last", defaultValue: "Last Update"),
                        selection: $lastID
                    ) {
                        ForEach(pages, id: \.listID) { page in
                            Text(page.id).tag(page.listID)
                        }
                    }
                    .accessibilityIdentifier("MobileWhatsNewReplayLast")
                }
                .pickerStyle(.menu)

                Section {
                    ForEach(selection?.pages ?? [], id: \.listID) { page in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(page.title)
                            Text(page.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        replay = selection
                    } label: {
                        Label(
                            L10n.string("mobile.whatsNew.debug.show", defaultValue: "Show Sheets"),
                            systemImage: "play.rectangle"
                        )
                    }
                    .disabled(selection == nil)
                    .accessibilityIdentifier("MobileWhatsNewReplayShow")
                }
            }
        }
        .navigationTitle(L10n.string("mobile.whatsNew.debug.title", defaultValue: "Replay What's New"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileWhatsNewDebugView")
        .sheet(item: $replay) { replay in
            MobileWhatsNewSheet(
                pages: replay.pages,
                allowedWebHosts: allowedWebHosts,
                dismiss: { self.replay = nil }
            )
        }
    }
}
#endif
