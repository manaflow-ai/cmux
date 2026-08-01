import Foundation

extension SimulatorRect {
    var isValidUIAutomationFrame: Bool {
        x.isFinite && y.isFinite
            && width.isFinite && height.isFinite
            && width > 0 && height > 0
    }
}

extension String {
    var normalizedUIAutomationText: String? {
        var normalized = ""
        normalized.reserveCapacity(utf8.count)
        var pendingSpace = false
        for character in self {
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
}
