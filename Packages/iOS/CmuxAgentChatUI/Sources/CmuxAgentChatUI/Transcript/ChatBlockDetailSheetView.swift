import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ChatBlockDetailSheetView: View {
    let detail: ChatBlockDetail
    let onOpenTerminal: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    init(detail: ChatBlockDetail, onOpenTerminal: (() -> Void)? = nil) {
        self.detail = detail
        self.onOpenTerminal = onOpenTerminal
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let subtitle = detail.subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    ForEach(detail.sections) { section in
                        ChatBlockDetailSectionView(section: section)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(detail.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "chat.detail.done", defaultValue: "Done", bundle: .module)) {
                        dismiss()
                    }
                    .accessibilityIdentifier("ChatBlockDetailDoneButton")
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    openTerminalButton
                    copyAllButton
                }
                #else
                ToolbarItemGroup(placement: .confirmationAction) {
                    openTerminalButton
                    copyAllButton
                }
                #endif
            }
        }
        .accessibilityIdentifier("ChatBlockDetailSheet")
    }

    @ViewBuilder
    private var openTerminalButton: some View {
        if let onOpenTerminal {
            Button(action: onOpenTerminal) {
                Label(
                    String(
                        localized: "chat.terminal.open_in_terminal",
                        defaultValue: "Open in terminal",
                        bundle: .module
                    ),
                    systemImage: "terminal"
                )
            }
            .accessibilityIdentifier("ChatBlockDetailOpenTerminalButton")
        }
    }

    private var copyAllButton: some View {
        Button(action: copyAll) {
            Text(String(localized: "chat.detail.copy_all", defaultValue: "Copy All", bundle: .module))
                .fontWeight(.regular)
        }
        .disabled(detail.copyText.isEmpty)
        .accessibilityIdentifier("ChatBlockDetailCopyAllButton")
    }

    private func copyAll() {
        guard !detail.copyText.isEmpty else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = detail.copyText
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detail.copyText, forType: .string)
        #endif
    }
}
