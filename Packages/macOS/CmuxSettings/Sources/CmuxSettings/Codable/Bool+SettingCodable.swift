import Foundation

extension Bool: SettingCodable {
    public static func decodeFromUserDefaults(_ raw: Any?) -> Bool? {
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        if let bool = raw as? Bool { return bool }
        return nil
    }

    public func encodeForUserDefaults() -> Any { self }

    public static func decodeFromJSON(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    public func encodeForJSON() -> Any { self }
}
