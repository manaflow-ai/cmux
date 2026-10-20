import CmuxSettings
import SwiftUI

/// A labeled `TextField` bound to a `String` JSON-backed setting.
///
/// Used for free-form text settings persisted in the cmux JSON config
/// file (e.g. ``SettingCatalog/automation/socketPassword``). Writes round
/// through the actor on every commit; transient typing state lives in
/// local `@State`.
@MainActor
public struct SettingsTextFieldRow: View {
    private let model: JSONValueModel<String>
    private let title: String
    private let placeholder: String

    @State private var draft: String = ""
    @State private var loaded: Bool = false

    public init(
        model: JSONValueModel<String>,
        title: String,
        placeholder: String = ""
    ) {
        self.model = model
        self.title = title
        self.placeholder = placeholder
    }

    public var body: some View {
        HStack {
            Text(title)
            TextField(placeholder, text: $draft, onCommit: {
                model.set(draft)
            })
            .textFieldStyle(.roundedBorder)
        }
        .task {
            model.startObserving()
            // Hydrate the draft from the model on first appearance and
            // keep it in sync with externally-driven changes.
            if !loaded {
                draft = model.current
                loaded = true
            }
        }
        .onChange(of: model.current) { _, newValue in
            // External change (file watcher) — refresh the draft only if
            // the user isn't actively editing.
            if draft != newValue {
                draft = newValue
            }
        }
    }
}
