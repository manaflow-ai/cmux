#if !canImport(Darwin)
import Foundation

extension String {
    /// Linux Foundation has no `String(localized:)`; the package lane's tests there read the
    /// development-language text. The app only ships on Apple platforms, which use the real one.
    init(localized value: String) { self = value }
}
#endif
