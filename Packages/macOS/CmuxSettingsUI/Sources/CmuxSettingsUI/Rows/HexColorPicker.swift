import SwiftUI

@MainActor
struct HexColorPicker: View {
    private let storedHex: String
    private let onChange: (String) -> Void

    @State private var selection: HexColorPickerSelection

    init(storedHex: String, fallback: Color, onChange: @escaping (String) -> Void) {
        self.storedHex = storedHex
        self.onChange = onChange
        _selection = State(initialValue: HexColorPickerSelection(storedHex: storedHex, fallback: fallback))
    }

    var body: some View {
        ColorPicker(
            selection: Binding(
                get: { selection.color },
                set: { newColor in
                    onChange(selection.applyPickerSelection(newColor))
                }
            ),
            supportsOpacity: false
        ) {
            EmptyView()
        }
        .labelsHidden()
        .frame(width: 38)
        .onChange(of: storedHex) { _, newHex in
            selection.reconcile(storedHex: newHex)
        }
    }
}
