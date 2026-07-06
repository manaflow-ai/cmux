import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ChatBlockDetailSheetView: View {
    let detail: ChatBlockDetail

    @Environment(\.dismiss) private var dismiss

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
                ToolbarItem(placement: .topBarTrailing) { copyAllButton }
                #else
                ToolbarItem(placement: .confirmationAction) { copyAllButton }
                #endif
            }
        }
        .accessibilityIdentifier("ChatBlockDetailSheet")
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
