import SwiftUI

struct BrowserDesignModeValueField: View {
    let title: String
    let currentValue: String
    let onChange: (String) -> Void

    @State private var value: String
    @State private var submittedValue: String?
    @FocusState private var isFocused: Bool

    init(
        title: String,
        currentValue: String,
        onChange: @escaping (String) -> Void
    ) {
        self.title = title
        self.currentValue = currentValue
        self.onChange = onChange
        _value = State(initialValue: currentValue)
    }

    var body: some View {
        LabeledContent(title) {
            TextField(
                title,
                text: $value
            )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { wasFocused, focused in
                    if focused {
                        submittedValue = nil
                    } else if wasFocused {
                        commit()
                    }
                }
                .onChange(of: currentValue) { _, next in
                    if !isFocused, value != next { value = next }
                }
        }
        .cmuxFont(size: 11)
    }

    private func commit() {
        guard value != currentValue, value != submittedValue else { return }
        submittedValue = value
        onChange(value)
    }
}
