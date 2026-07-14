import SwiftUI

struct BrowserDesignModeValueField: View {
    let title: String
    let currentValue: String
    let onChange: (String) -> Void

    @State private var value: String

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
                text: Binding(
                    get: { value },
                    set: { next in
                        value = next
                        onChange(next)
                    }
                )
            )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .onChange(of: currentValue) { _, next in
                    if value != next { value = next }
                }
        }
        .cmuxFont(size: 11)
    }
}
