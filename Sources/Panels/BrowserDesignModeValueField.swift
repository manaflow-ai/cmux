import SwiftUI

struct BrowserDesignModeValueField: View {
    let title: String
    let currentValue: String
    let onChange: @MainActor (String) async -> String

    @State private var value: String
    @State private var submittedValue: String?
    @FocusState private var isFocused: Bool

    init(
        title: String,
        currentValue: String,
        onChange: @escaping @MainActor (String) async -> String
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
                    if wasFocused && !focused { commit() }
                }
                .onChange(of: currentValue) { _, next in
                    if submittedValue == value || (!isFocused && submittedValue == nil) {
                        value = next
                        submittedValue = nil
                    }
                }
        }
        .cmuxFont(size: 11)
    }

    private func commit() {
        guard value != currentValue, value != submittedValue else { return }
        let submission = value
        submittedValue = submission
        Task { @MainActor in
            let authoritativeValue = await onChange(submission)
            guard submittedValue == submission, value == submission else { return }
            value = authoritativeValue
            submittedValue = nil
        }
    }
}
