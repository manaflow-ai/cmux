public import SwiftUI

extension EnvironmentValues {
    /// The style `Icon` draws in; set with `.iconStyle(_:)`.
    @Entry public var iconStyle: IconStyle = .line
    /// Whether `Icon` draws Cat drawings; set with `.iconAccent(_:)`.
    @Entry public var iconAccent: IconAccent = .none
    /// The color of accent layers; nil uses `Color.accentColor`.
    @Entry public var iconAccentColor: Color? = nil
}
