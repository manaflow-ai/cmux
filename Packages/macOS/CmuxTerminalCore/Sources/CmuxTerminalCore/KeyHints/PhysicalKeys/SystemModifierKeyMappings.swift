import Foundation

/// System Settings' per-keyboard modifier keys (Keyboard > Keyboard
/// Shortcuts > Modifier Keys).
///
/// macOS stores each keyboard's choices in the global preferences as
/// `com.apple.keyboard.modifiermapping.<vendor>-<product>-0`, an array of
/// source and destination usage pairs, usually in the current-host domain.
public struct SystemModifierKeyMappings: Sendable, Equatable {
    /// The mapping for each keyboard, by vendor and product id.
    public var mappings: [DeviceID: HIDKeyMapping]

    /// A keyboard's vendor and product id.
    public struct DeviceID: Hashable, Sendable {
        public var vendorID: Int
        public var productID: Int

        public init(vendorID: Int, productID: Int) {
            self.vendorID = vendorID
            self.productID = productID
        }
    }

    /// No keyboard has modifier keys changed.
    public static let none = SystemModifierKeyMappings(mappings: [:])

    /// - Parameter mappings: The mapping for each keyboard.
    public init(mappings: [DeviceID: HIDKeyMapping]) {
        self.mappings = mappings
    }

    /// Reads the modifier mappings out of global preference domains.
    ///
    /// - Parameter domains: Global preference dictionaries, lowest priority
    ///   first (the any-host domain, then the current-host domain). A later
    ///   domain's entry for the same keyboard wins. Keys other than
    ///   `com.apple.keyboard.modifiermapping.*` are ignored.
    public init(globalDomains domains: [[String: Any]]) {
        var mappings: [DeviceID: HIDKeyMapping] = [:]
        let prefix = "com.apple.keyboard.modifiermapping."
        for domain in domains {
            for (key, value) in domain where key.hasPrefix(prefix) {
                let parts = key.dropFirst(prefix.count).split(separator: "-")
                guard parts.count >= 2, let vendor = Int(parts[0]), let product = Int(parts[1]) else { continue }
                mappings[DeviceID(vendorID: vendor, productID: product)] = HIDKeyMapping(propertyList: value)
            }
        }
        self.init(mappings: mappings)
    }

    /// The mapping for a keyboard; identity when it has none.
    public func mapping(for device: KeyboardDevice) -> HIDKeyMapping {
        mappings[DeviceID(vendorID: device.vendorID, productID: device.productID)] ?? .identity
    }
}
