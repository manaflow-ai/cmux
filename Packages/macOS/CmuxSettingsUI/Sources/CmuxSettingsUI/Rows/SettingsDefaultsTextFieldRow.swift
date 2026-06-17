import CmuxSettings
import SwiftUI

/// A labeled `TextField` bound to a `String` UserDefaults-backed setting
/// via ``DefaultsValueModel``.
///
/// Sibling of ``SettingsTextFieldRow`` (which binds to a
/// JSON-config-backed setting); the two are split because the underlying
/// value model types differ (``DefaultsValueModel<String>`` vs.
/// ``JSONValueModel<String>``) and unifying them would require
/// existential erasure that adds nothing at the call site.
@MainActor
public struct SettingsDefaultsTextFieldRow: View {
    private let model: DefaultsValueModel<String>
    private let title: String
    private let placeholder: String
    private let subtitle: String?

    @State private var draft: String = ""
    @State private var loaded: Bool = false

    public init(
        model: DefaultsValueModel<String>,
        title: String,
        placeholder: String = "",
        subtitle: String? = nil
    ) {
        self.model = model
        self.title = title
        self.placeholder = placeholder
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                TextField(placeholder, text: $draft, onCommit: {
                    model.set(draft)
                })
                .textFieldStyle(.roundedBorder)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            model.startObserving()
            if !loaded {
                draft = model.current
                loaded = true
            }
        }
        .onChange(of: model.current) { _, newValue in
            if draft != newValue {
                draft = newValue
            }
        }
    }
}
