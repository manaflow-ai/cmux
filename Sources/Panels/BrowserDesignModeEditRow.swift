import CmuxBrowser
import SwiftUI

struct BrowserDesignModeEditRow: View {
    let edit: BrowserDesignModeEdit
    let onRevert: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(edit.property)
                    .cmuxFont(size: 10.5, weight: .medium)
                Text("\(edit.originalValue) → \(edit.value)")
                    .cmuxFont(size: 9.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Button(action: onRevert) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .safeHelp(String(localized: "browser.designMode.revertEdit", defaultValue: "Revert this edit"))
        }
        .padding(.vertical, 2)
    }
}
