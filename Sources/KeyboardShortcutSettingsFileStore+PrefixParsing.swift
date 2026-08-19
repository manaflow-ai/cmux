import CmuxSettings
import Foundation

extension CmuxSettingsFileStore {
    /// Parses the optional single-stroke leader under `shortcuts.prefix`.
    /// Prefixes intentionally use the same human-readable syntax as action
    /// bindings, but a two-stroke value is rejected so the state machine never
    /// has to guess which part is the leader.
    func parseShortcutPrefixValue(_ rawValue: Any?) -> StoredShortcut? {
        guard let rawValue else { return .unbound }
        if rawValue is NSNull { return .unbound }
        let parsed: StoredShortcut?
        if let string = jsonString(rawValue) {
            parsed = StoredShortcut.parseConfig(string)
        } else if let strokes = jsonStringArray(rawValue) {
            parsed = strokes.isEmpty
                ? .unbound
                : (strokes.count == 1 ? StoredShortcut.parseConfig(strokes: strokes) : nil)
        } else if let object = rawValue as? [String: Any] {
            parsed = parseShortcutObjectForm(object, allowsBareFirstStroke: false)
        } else {
            parsed = nil
        }

        guard let parsed,
              let normalized = CmuxSettings.ShortcutPrefixPolicy().normalized(
                  parsed.cmuxSettingsStoredShortcut
              ) else {
            return nil
        }
        return StoredShortcut(cmuxSettingsStoredShortcut: normalized)
    }

    /// Decodes the nested-object binding the CmuxSettings package writes.
    func parseShortcutObjectForm(
        _ object: [String: Any],
        allowsBareFirstStroke: Bool
    ) -> StoredShortcut? {
        guard let firstValue = object["first"],
              let first = parseShortcutStrokeObject(firstValue) else {
            return nil
        }
        if first.key.isEmpty {
            // An empty first stroke is the explicit unbound marker only when
            // the object does not carry a second stroke.
            guard object["second"] == nil || object["second"] is NSNull else {
                return nil
            }
            return .unbound
        }
        guard allowsBareFirstStroke || !first.modifierFlags.isEmpty || first.key == "space" else {
            return nil
        }
        let second: ShortcutStroke?
        if let secondValue = object["second"], !(secondValue is NSNull) {
            // A malformed second stroke invalidates the whole binding rather
            // than silently dropping the chord half.
            guard let parsedSecond = parseShortcutStrokeObject(secondValue),
                  !parsedSecond.key.isEmpty else {
                return nil
            }
            second = parsedSecond
        } else {
            second = nil
        }
        return StoredShortcut(first: first, second: second)
    }

    func parseShortcutStrokeObject(_ rawValue: Any) -> ShortcutStroke? {
        if rawValue is NSNull { return nil }
        guard let dict = rawValue as? [String: Any],
              let key = jsonString(dict["key"]) else {
            return nil
        }
        // An out-of-range keyCode is corrupt input, not a key to wrap.
        let keyCode: UInt16?
        if let rawKeyCode = jsonInt(dict["keyCode"]) {
            guard let value = UInt16(exactly: rawKeyCode) else { return nil }
            keyCode = value
        } else {
            keyCode = nil
        }
        return ShortcutStroke(
            key: canonicalShortcutKey(key, keyCode: keyCode),
            command: jsonBool(dict["command"]) ?? false,
            shift: jsonBool(dict["shift"]) ?? false,
            option: jsonBool(dict["option"]) ?? false,
            control: jsonBool(dict["control"]) ?? false,
            keyCode: keyCode
        )
    }
}
