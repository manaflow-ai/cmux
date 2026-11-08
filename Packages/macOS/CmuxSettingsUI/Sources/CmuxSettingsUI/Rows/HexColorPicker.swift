import SwiftUI

@MainActor
struct HexColorPicker: View {
    private let reconcileState: HexColorPickerReconcileState
    private let onChange: (String) -> Void

    @State private var selection: HexColorPickerSelection

    init(storedHex: String, fallback: Color, reconcileRevision: Int, onChange: @escaping (String) -> Void) {
        let initialState = HexColorPickerReconcileState(storedHex: storedHex, revision: reconcileRevision)
        self.reconcileState = initialState
        self.onChange = onChange
        _selection = State(initialValue: HexColorPickerSelection(state: initialState, fallback: fallback))
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
        .onChange(of: reconcileState) { _, newState in
            selection.reconcile(state: newState)
        }
    }
}
