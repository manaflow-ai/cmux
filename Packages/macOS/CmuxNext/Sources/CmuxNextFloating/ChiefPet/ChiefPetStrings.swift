import Foundation

/// Text of the Chief pet. Keys live in Resources/ChiefPet.xcstrings.
enum ChiefPetStrings {
    static var accessibilityLabel: String {
        String(localized: "chiefPet.accessibilityLabel", defaultValue: "Chief", table: "ChiefPet", bundle: .module)
    }
}
