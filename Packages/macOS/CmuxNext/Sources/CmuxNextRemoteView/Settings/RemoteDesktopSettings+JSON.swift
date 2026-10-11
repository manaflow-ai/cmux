import Foundation

extension RemoteDesktopSettings {
    /// Reads the settings from a parsed cmux.json object. Accepts dotted
    /// keys (`"remoteDesktop.keyboard.mode": "text"`) and nested objects
    /// (`"remoteDesktop": {"keyboard": {"mode": "text"}}`). A missing or
    /// invalid value keeps its default, so one bad key never resets the rest.
    public init(json: [String: Any]) {
        self.init()
        let lookup = Lookup(root: json)
        if let value = lookup.string("remoteDesktop.quality").flatMap(RemoteQualityPreset.init(rawValue:)) { quality = value }
        maxFps = lookup.autoOrInt("remoteDesktop.maxFps", in: 1...240) ?? maxFps
        maxBitrateMbps = lookup.autoOrDouble("remoteDesktop.maxBitrateMbps", in: 0.1...80) ?? maxBitrateMbps
        if let value = lookup.string("remoteDesktop.codec").flatMap(Codec.init(rawValue:)) { codec = value }
        if let value = lookup.string("remoteDesktop.resolution").flatMap(Resolution.init(rawValue:)) { resolution = value }
        if let value = lookup.string("remoteDesktop.keyboard.mode").flatMap(RemoteKeyboardMode.init(rawValue:)) {
            keyboardMode = value
        }
        if let value = lookup.bool("remoteDesktop.keyboard.sendSystemShortcuts") { sendSystemShortcuts = value }
        if let value = lookup.string("remoteDesktop.clipboard").flatMap(Clipboard.init(rawValue:)) { clipboard = value }
        if let value = lookup.bool("remoteDesktop.audio") { audio = value }
        if let value = lookup.int("remoteDesktop.interactiveMaxRttMs"), (0...10_000).contains(value) {
            interactiveMaxRttMs = value
        }
        if let value = lookup.bool("remoteDesktop.showPathBadge") { showPathBadge = value }
    }
}

/// Dotted-key lookup over a JSON object, flat or nested.
private nonisolated struct Lookup {
    let root: [String: Any]

    func value(_ key: String) -> Any? {
        if let flat = root[key] { return flat }
        var node: Any? = root
        for part in key.split(separator: ".") {
            guard let object = node as? [String: Any] else { return nil }
            node = object[String(part)]
        }
        return node
    }

    func string(_ key: String) -> String? { value(key) as? String }

    func bool(_ key: String) -> Bool? {
        guard let number = value(key) as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    func int(_ key: String) -> Int? {
        guard let number = value(key) as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.rounded() == double ? Int(double) : nil
    }

    /// `.some(nil)` for "auto", `.some(n)` for a valid number, nil otherwise.
    func autoOrInt(_ key: String, in range: ClosedRange<Int>) -> Int?? {
        if string(key) == "auto" { return .some(nil) }
        guard let value = int(key), range.contains(value) else { return nil }
        return .some(value)
    }

    func autoOrDouble(_ key: String, in range: ClosedRange<Double>) -> Double?? {
        if string(key) == "auto" { return .some(nil) }
        guard let number = value(key) as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              range.contains(number.doubleValue) else { return nil }
        return .some(number.doubleValue)
    }
}
