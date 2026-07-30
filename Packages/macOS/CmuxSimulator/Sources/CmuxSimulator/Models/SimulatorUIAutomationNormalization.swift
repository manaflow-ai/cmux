import Foundation

func simulatorUIAutomationIsValidFrame(_ frame: SimulatorRect) -> Bool {
    frame.x.isFinite && frame.y.isFinite
        && frame.width.isFinite && frame.height.isFinite
        && frame.width > 0 && frame.height > 0
}

func simulatorUIAutomationNormalizedText(_ value: String?) -> String? {
    guard let value else { return nil }
    var normalized = ""
    normalized.reserveCapacity(value.utf8.count)
    var pendingSpace = false
    for character in value {
        if character.isWhitespace {
            pendingSpace = !normalized.isEmpty
            continue
        }
        if pendingSpace {
            normalized.append(" ")
            pendingSpace = false
        }
        normalized.append(character)
    }
    return normalized.isEmpty ? nil : normalized
}
