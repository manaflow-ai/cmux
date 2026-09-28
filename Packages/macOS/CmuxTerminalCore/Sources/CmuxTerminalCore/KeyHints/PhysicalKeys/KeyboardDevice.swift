/// A connected keyboard, as the HID registry describes it.
public struct KeyboardDevice: Hashable, Sendable {
    /// The product name the keyboard reports (`Apple Internal Keyboard / Trackpad`).
    public var name: String
    /// The USB or Bluetooth vendor id; `0` when the keyboard reports none.
    public var vendorID: Int
    /// The product id; `0` when the keyboard reports none.
    public var productID: Int
    /// Whether this is the Mac's built-in keyboard.
    public var isBuiltIn: Bool

    /// - Parameters:
    ///   - name: The product name the keyboard reports.
    ///   - vendorID: The vendor id, `0` when absent (built-in keyboards on
    ///     Apple silicon report none).
    ///   - productID: The product id, `0` when absent.
    ///   - isBuiltIn: Whether this is the Mac's built-in keyboard.
    public init(name: String, vendorID: Int, productID: Int, isBuiltIn: Bool) {
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.isBuiltIn = isBuiltIn
    }

    /// Whether this is Karabiner-Elements' virtual keyboard, which exists
    /// while Karabiner is running and sends every key Karabiner remapped.
    public var isKarabinerVirtualKeyboard: Bool {
        name.localizedCaseInsensitiveContains("Karabiner") && name.localizedCaseInsensitiveContains("VirtualHIDKeyboard")
    }
}
