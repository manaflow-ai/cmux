import SwiftUI

@MainActor
struct HexColorPicker: View {
    private let storedHex: String
    private let reconcileRevision: Int
    private let onChange: (String) -> Void

    @State private var selection: HexColorPickerSelection

    init(storedHex: String, fallback: Color, reconcileRevision: Int, onChange: @escaping (String) -> Void) {
        self.storedHex = storedHex
        self.reconcileRevision = reconcileRevision
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
        .onChange(of: reconcileRevision) { _, _ in
            selection.reconcile(storedHex: storedHex)
        }
    }
}
