#if canImport(UIKit)
import CmuxMobileSupport
import SwiftUI

struct MobileDiffFileList: View {
    let state: MobileDiffState
    let dismiss: () -> Void

    var body: some View {
        let selectedFileID = state.selectedFileID
        NavigationStack {
            List(state.files) { file in
                Button {
                    state.selectFile(id: file.id)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: file.id == selectedFileID ? "checkmark.circle.fill" : "doc.text")
                            .foregroundStyle(file.id == selectedFileID ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.name).foregroundStyle(.primary)
                            Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 5) {
                            Text(verbatim: "+\(file.added)").foregroundStyle(.green)
                            Text(verbatim: "−\(file.deleted)").foregroundStyle(.red)
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
                .accessibilityIdentifier("MobileDiffFile-\(file.id)")
            }
            .navigationTitle(L10n.string("mobile.diff.files", defaultValue: "Changed Files"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done"), action: dismiss)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
