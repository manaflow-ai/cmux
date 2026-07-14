import CmuxSettings
import SwiftUI

struct LeaderKeyBindingRow: View {
    let action: LeaderKeyAction
    let model: DefaultsValueModel<String>

    var body: some View {
        HStack {
            Text(action.label)
            Spacer()
            ShortcutRecorderView(
                placeholder: ShortcutDisplayFormatter().keyDisplayString(model.current),
                firstStrokeRequiresModifier: false
            ) { stroke in
                guard !stroke.command, !stroke.control, !stroke.option else { return }
                model.set(stroke.key)
            }
            .accessibilityLabel(Text(action.label))
            .frame(width: 120)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
