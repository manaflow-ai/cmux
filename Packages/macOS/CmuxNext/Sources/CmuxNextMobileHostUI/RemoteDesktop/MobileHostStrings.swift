import Foundation

/// User-facing strings of the phone link's Mac UI (en, ja and the other
/// shipped languages in Resources/Localizable.xcstrings).
enum MobileHostStrings {
    static func consentTitle(device: String, target: String, control: Bool) -> String {
        control
            ? String(format: String(localized: "mobileHost.consent.control", defaultValue: "%1$@ wants to control %2$@",
                                    bundle: .module), device, target)
            : String(format: String(localized: "mobileHost.consent.view", defaultValue: "%1$@ wants to view %2$@",
                                    bundle: .module), device, target)
    }

    static var consentMessage: String {
        String(localized: "mobileHost.consent.message",
               defaultValue: "The phone will see this screen. Allow only if you started this from your phone.", bundle: .module)
    }

    static var allow: String { String(localized: "mobileHost.consent.allow", defaultValue: "Allow", bundle: .module) }
    static var deny: String { String(localized: "mobileHost.consent.deny", defaultValue: "Deny", bundle: .module) }

    static var unknownDevice: String {
        String(localized: "mobileHost.consent.unknownDevice", defaultValue: "A paired device", bundle: .module)
    }

    static func indicatorEntry(device: String, target: String, control: Bool) -> String {
        control
            ? String(format: String(localized: "mobileHost.indicator.controlled", defaultValue: "%1$@ is controlling %2$@",
                                    bundle: .module), device, target)
            : String(format: String(localized: "mobileHost.indicator.viewed", defaultValue: "%1$@ is viewing %2$@",
                                    bundle: .module), device, target)
    }

    static var stop: String { String(localized: "mobileHost.indicator.stop", defaultValue: "Stop", bundle: .module) }
    static var stopAll: String { String(localized: "mobileHost.indicator.stopAll", defaultValue: "Stop All", bundle: .module) }

    static var indicatorLabel: String {
        String(localized: "mobileHost.indicator.label", defaultValue: "Screen shared with a phone", bundle: .module)
    }
}
