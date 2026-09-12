/// CDP's platform-independent virtual key identity used by Blink editing.
struct ChromiumVirtualKey {
    let value: Int

    init(code: String) {
        let fixed = ["Backspace": 8, "Tab": 9, "Enter": 13, "Escape": 27,
                     "Space": 32, "PageUp": 33, "PageDown": 34, "End": 35,
                     "Home": 36, "ArrowLeft": 37, "ArrowUp": 38,
                     "ArrowRight": 39, "ArrowDown": 40, "Delete": 46]
        if let mapped = fixed[code] {
            value = mapped
        } else if code.hasPrefix("Key"), code.count == 4, let scalar = code.unicodeScalars.last {
            value = Int(scalar.value)
        } else if code.hasPrefix("Digit"), code.count == 6, let scalar = code.unicodeScalars.last {
            value = Int(scalar.value)
        } else {
            value = 0
        }
    }
}
