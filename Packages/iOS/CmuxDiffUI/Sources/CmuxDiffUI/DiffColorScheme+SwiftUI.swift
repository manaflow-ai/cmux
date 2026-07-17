import SwiftUI

extension DiffColorScheme {
    init(_ colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .dark : .light
    }
}
