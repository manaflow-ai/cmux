import Foundation

/// Text of the Chief pet. Keys live in Resources/ChiefPet.xcstrings.
enum ChiefPetStrings {
    static var accessibilityLabel: String {
        String(localized: "chiefPet.accessibilityLabel", defaultValue: "Chief", table: "ChiefPet", bundle: .module)
    }

    static var expand: String {
        String(localized: "chiefPet.expand", defaultValue: "Show Chief", table: "ChiefPet", bundle: .module)
    }

    static var compose: String {
        String(localized: "chiefPet.compose", defaultValue: "New Message", table: "ChiefPet", bundle: .module)
    }
}
