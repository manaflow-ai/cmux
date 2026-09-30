import CmuxNextActions
import CmuxNextDesign
import SwiftUI

/// The recorder's message and choices under the row being recorded.
struct RecorderPanel: View {
    let model: SettingsWindowModel
    let state: ShortcutRecorderState

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            if let message = state.message {
                Text(message).font(SettingsStyle.caption).foregroundStyle(SettingsStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cmux.settings.recorder.message")
            }
            HStack(spacing: Metrics.space3) {
                ForEach(options, id: \.self) { option in
                    Button(ShortcutRecorderStrings.title(option)) { model.chooseRecorderOption(option) }
                        .buttonStyle(SettingsButtonStyle(destructive: option == .remove))
                        .disabled(option == .restoreDefault && !state.hasDefault)
                }
            }
        }
    }

    private var options: [ShortcutRecorderOption] {
        state.options.map { $0 }
    }
}
