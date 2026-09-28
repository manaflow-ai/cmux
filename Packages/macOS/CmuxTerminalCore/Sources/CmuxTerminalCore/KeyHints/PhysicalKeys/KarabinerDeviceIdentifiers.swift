/// The `identifiers` object Karabiner-Elements uses to pick a device, in a
/// `devices` entry or a `device_if` condition.
struct KarabinerDeviceIdentifiers: Sendable, Equatable {
    var vendorID: Int?
    var productID: Int?
    var isKeyboard: Bool?
    var isPointingDevice: Bool?
    var isBuiltInKeyboard: Bool?
    /// Whether the object names something cmux can't check (`location_id`,
    /// `device_address`, `is_game_pad`).
    var hasUncheckableField = false

    init(vendorID: Int? = nil, productID: Int? = nil, isKeyboard: Bool? = nil,
         isPointingDevice: Bool? = nil, isBuiltInKeyboard: Bool? = nil, hasUncheckableField: Bool = false) {
        self.vendorID = vendorID
        self.productID = productID
        self.isKeyboard = isKeyboard
        self.isPointingDevice = isPointingDevice
        self.isBuiltInKeyboard = isBuiltInKeyboard
        self.hasUncheckableField = hasUncheckableField
    }

    init(json: [String: Any]) {
        for (key, value) in json {
            switch key {
            case "vendor_id": vendorID = value as? Int
            case "product_id": productID = value as? Int
            case "is_keyboard": isKeyboard = value as? Bool
            case "is_pointing_device": isPointingDevice = value as? Bool
            case "is_built_in_keyboard": isBuiltInKeyboard = value as? Bool
            case "description": continue
            default: hasUncheckableField = true
            }
        }
    }

    /// Whether a `devices` entry with these identifiers is `device`, or
    /// `nil` when that can't be told.
    ///
    /// Karabiner matches a `devices` entry on every identifier, and writes
    /// only the ones that aren't 0 or false: `{"is_keyboard": true}` is the
    /// built-in keyboard (vendor and product 0), not every keyboard.
    func isEntry(for device: KeyboardDevice) -> Bool? {
        guard isKeyboard == true, (vendorID ?? 0) == device.vendorID, (productID ?? 0) == device.productID else {
            return false
        }
        if isBuiltInKeyboard == false, device.isBuiltIn { return false }
        return hasUncheckableField ? nil : true
    }

    /// Whether these identifiers, in a `device_if` condition, pick
    /// `device`, a keyboard, or `nil` when that can't be told. Fields left
    /// out match anything.
    func matches(_ device: KeyboardDevice) -> Bool? {
        if isKeyboard == false { return false }
        if isBuiltInKeyboard == true, !device.isBuiltIn { return false }
        if isBuiltInKeyboard == false, device.isBuiltIn { return false }
        if let vendorID, vendorID != device.vendorID { return false }
        if let productID, productID != device.productID { return false }
        if hasUncheckableField { return nil }
        return true
    }
}
