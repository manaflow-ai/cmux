import SwiftUI

@MainActor
struct HexColorPickerSelection {
    private let fallback: Color
    private(set) var color: Color

    init(storedHex: String, fallback: Color) {
        self.fallback = fallback
        self.color = Color(cmuxHex: storedHex) ?? fallback
    }

    mutating func applyPickerSelection(_ newColor: Color) -> String {
        color = newColor
        return newColor.cmuxHexString
    }

    mutating func reconcile(storedHex: String) {
        guard storedHex != color.cmuxHexString else { return }
        color = Color(cmuxHex: storedHex) ?? fallback
    }
}
