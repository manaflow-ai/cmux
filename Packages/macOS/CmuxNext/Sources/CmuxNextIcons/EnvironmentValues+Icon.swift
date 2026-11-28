public import SwiftUI

extension EnvironmentValues {
    /// The style `Icon` draws in; set with `.iconStyle(_:)`.
    @Entry public var iconStyle: IconStyle = .line
    /// Whether `Icon` draws Cat drawings; set with `.iconAccent(_:)`.
    @Entry public var iconAccent: IconAccent = .none
    /// The color of accent layers; nil draws them in the secondary ink, never the system accent.
    @Entry public var iconAccentColor: Color? = nil
}
