/// Which kind of phone a phone tab shows (plans/cmux-next/phone.md,
/// plans/cmux-next/simulators-DESIGN.md).
public enum PhoneMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// An iOS Simulator device, driven by `simctl`.
    case simulator = "sim"
    /// A real iPhone paired over USB or Wi-Fi, driven by `devicectl`.
    case device = "dev"
    /// An iOS virtual machine run by an external tool's local API.
    case virtualMachine = "vm"
    /// An Android Virtual Device (by AVD name), run by the SDK's `emulator`.
    case emulator = "avd"
    /// A real Android phone on USB or Wi-Fi debugging, by its `adb` serial.
    case androidDevice = "adb"

    /// True for the Android modes, which the Android backend serves.
    public var isAndroid: Bool { self == .emulator || self == .androidDevice }
}
