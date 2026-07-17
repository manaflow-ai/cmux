import Foundation

extension Decoder {
    func rejectUnknownDockConfigKeys(allowedKeys: Set<String>) throws {
        let container = try container(keyedBy: DockConfigCodingKey.self)
        guard container.allKeys.contains(where: { !allowedKeys.contains($0.stringValue) }) else {
            return
        }
        throw DockConfigValidationError(
            message: String(
                localized: "dock.error.unknownKey",
                defaultValue: "Dock config contains an unknown key. Check dock.json and try again."
            )
        )
    }
}
