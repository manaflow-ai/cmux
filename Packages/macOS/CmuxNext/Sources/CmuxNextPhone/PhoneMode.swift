/// Which kind of iPhone a phone tab shows (plans/cmux-next/phone.md).
public enum PhoneMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// An iOS Simulator device, driven by `simctl`.
    case simulator = "sim"
    /// A real iPhone paired over USB or Wi-Fi, driven by `devicectl`.
    case device = "dev"
    /// An iOS virtual machine run by an external tool's local API.
    case virtualMachine = "vm"
}
