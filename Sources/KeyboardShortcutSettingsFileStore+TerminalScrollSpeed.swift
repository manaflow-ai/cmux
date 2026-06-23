import Foundation

func applyTerminalScrollSpeedSetting(
    from section: [String: Any],
    assign: (String, Double) -> Void,
    logInvalid: (String) -> Void
) {
    guard section.keys.contains("scrollSpeed") else { return }
    guard let number = section["scrollSpeed"] as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
        logInvalid("terminal.scrollSpeed")
        return
    }
    assign(
        TerminalScrollSpeedSettings.multiplierKey,
        TerminalScrollSpeedSettings.sanitizedMultiplier(number.doubleValue)
    )
}
