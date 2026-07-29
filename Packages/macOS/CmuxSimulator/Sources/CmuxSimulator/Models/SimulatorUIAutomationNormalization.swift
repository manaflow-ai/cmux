import Foundation

func simulatorUIAutomationIsValidFrame(_ frame: SimulatorRect) -> Bool {
    frame.x.isFinite && frame.y.isFinite
        && frame.width.isFinite && frame.height.isFinite
        && frame.width > 0 && frame.height > 0
}

func simulatorUIAutomationNormalizedText(_ value: String?) -> String? {
    guard let normalized = value?.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines),
          !normalized.isEmpty else {
        return nil
    }
    return normalized
}
