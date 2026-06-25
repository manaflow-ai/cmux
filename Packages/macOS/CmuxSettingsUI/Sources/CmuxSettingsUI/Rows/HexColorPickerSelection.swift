import SwiftUI

@MainActor
struct HexColorPickerSelection {
    private let fallback: Color
    private var pendingPickerHex: String?
    private(set) var color: Color

    init(storedHex: String, fallback: Color) {
        self.fallback = fallback
        self.color = Color(cmuxHex: storedHex) ?? fallback
    }

    mutating func applyPickerSelection(_ newColor: Color) -> String {
        color = newColor
        let hex = newColor.cmuxHexString
        pendingPickerHex = hex
        return hex
    }

    mutating func reconcile(storedHex: String) {
        if pendingPickerHex == storedHex {
            pendingPickerHex = nil
            return
        }
        pendingPickerHex = nil
        color = Color(cmuxHex: storedHex) ?? fallback
    }
}
