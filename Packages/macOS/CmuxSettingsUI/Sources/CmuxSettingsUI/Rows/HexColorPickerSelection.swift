import SwiftUI

@MainActor
struct HexColorPickerSelection {
    private let fallback: Color
    private var pendingPickerHex: String?
    private var pendingPickerReconcileRevision: Int?
    private var latestReconcileRevision: Int
    private(set) var color: Color

    init(state: HexColorPickerReconcileState, fallback: Color) {
        self.fallback = fallback
        self.latestReconcileRevision = state.revision
        self.color = Color(cmuxHex: state.storedHex) ?? fallback
    }

    mutating func applyPickerSelection(_ newColor: Color) -> String {
        color = newColor
        let hex = newColor.cmuxHexString
        pendingPickerHex = hex
        pendingPickerReconcileRevision = (pendingPickerReconcileRevision ?? latestReconcileRevision) + 1
        return hex
    }

    mutating func reconcile(state: HexColorPickerReconcileState) {
        latestReconcileRevision = state.revision
        if pendingPickerHex == state.storedHex,
           pendingPickerReconcileRevision == state.revision {
            pendingPickerHex = nil
            pendingPickerReconcileRevision = nil
            return
        }
        pendingPickerHex = nil
        pendingPickerReconcileRevision = nil
        color = Color(cmuxHex: state.storedHex) ?? fallback
    }
}
