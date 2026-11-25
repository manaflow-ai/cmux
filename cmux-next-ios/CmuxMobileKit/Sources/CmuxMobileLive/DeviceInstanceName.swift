import Foundation

/// The name this phone gives itself on the account: what Macs show in "Allow … to connect?", in
/// Settings > Mobile and in the device lists.
///
/// Each cmux build on a phone is its own device (its own Keychain group, so its own ids and keys), so
/// the name says which build it is: the App Store build goes by the phone's name alone, every other
/// build adds its label (`CmuxMobileInstanceLabel` in Info.plist, from `CMUX_MOBILE_INSTANCE_LABEL`
/// in project.yml): `Aziz's iPhone (INTERNAL)`, `Aziz's iPhone (BETA)`, `Aziz's iPhone (DEV)`. The
/// Mac app names itself the same way (CmuxNextMobile `MobileHostDeviceName`).
public struct DeviceInstanceName: Sendable, Equatable {
    /// The Info.plist key that carries the build's label (empty for the App Store build).
    public static let infoKey = "CmuxMobileInstanceLabel"

    /// The phone's own name (`UIDevice.name`).
    public let device: String
    /// The build's label; nil for the App Store build.
    public let label: String?

    public init(device: String, label: String?) {
        self.device = device
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = trimmed?.isEmpty == false ? trimmed : nil
    }

    /// The name of this phone in the running build (`bundle`'s `CmuxMobileInstanceLabel`; a `DEV`
    /// build with a tag, `CmuxMobileTag`, is `DEV <tag>`, so two tagged dev builds read apart).
    public init(device: String, bundle: Bundle) {
        self.init(device: device,
                  label: Self.label(bundle.object(forInfoDictionaryKey: Self.infoKey) as? String,
                                    tag: bundle.object(forInfoDictionaryKey: "CmuxMobileTag") as? String))
    }

    /// The label a build shows: `label`, with the tag added to a plain `DEV` (`.feedperf` → `DEV feedperf`).
    public static func label(_ label: String?, tag: String?) -> String? {
        let tag = tag?.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines)) ?? ""
        guard label?.trimmingCharacters(in: .whitespacesAndNewlines) == "DEV", !tag.isEmpty else { return label }
        return "DEV \(tag)"
    }

    /// The phone's name, then the build's label in parentheses when it has one.
    public var value: String {
        let name = device.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label else { return name }
        return name.isEmpty ? label : "\(name) (\(label))"
    }
}
