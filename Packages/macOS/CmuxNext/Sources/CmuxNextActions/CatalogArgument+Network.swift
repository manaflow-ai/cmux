import Foundation

/// Arguments of `cmux cloud set-network-access` (Internet Access…). Keys live in Localizable.xcstrings.
nonisolated extension CatalogArgument {
    /// The machine's internet access level (`cloudSetNetworkAccess`). The values are
    /// `CloudNetworkAccess`'s raw values; `trusted` is the allowlist of every preset the server
    /// serves (web/services/vms/networkPolicy.ts NETWORK_POLICY_PRESETS).
    static var networkAccessChoice: ActionArgument {
        ActionArgument(name: "access", title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.networkAccess") + "\u{E002}" + String(localized: "argument.networkAccess", defaultValue: "Internet Access", bundle: .module)), kind: .enumeration([
            ActionEnumCase(value: "full", title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.value.networkAccessFull") + "\u{E002}" + String(localized: "argument.value.networkAccessFull", defaultValue: "Full Internet", bundle: .module))),
            ActionEnumCase(value: "trusted", title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.value.networkAccessTrusted") + "\u{E002}" + String(localized: "argument.value.networkAccessTrusted",
                                                           defaultValue: "GitHub, Package Registries and Model Providers", bundle: .module))),
            ActionEnumCase(value: "none", title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.value.networkAccessNone") + "\u{E002}" + String(localized: "argument.value.networkAccessNone", defaultValue: "No Internet", bundle: .module))),
        ]))
    }
}
