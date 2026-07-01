import Foundation

/// Synthetic coding key used to index into surface tab bar button/menu arrays
/// when reporting decoding and validation errors.
struct CmuxSurfaceTabBarMenuCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = "menu[\(intValue)]"
        self.intValue = intValue
    }

    init(index: Int) {
        self.init(intValue: index)
    }
}
