public import Foundation
import SwiftUI

/// Text displayed by a mobile toast.
///
/// Use ``localized(_:defaultValue:bundle:comment:)`` for product copy and
/// ``verbatim(_:)`` for server-provided or user-provided text.
public enum MobileToastText: Equatable, Sendable {
    /// Copy resolved from a string catalog.
    case localized(LocalizedStringResource)

    /// Copy displayed exactly as supplied.
    case verbatim(String)

    /// Creates catalog-backed toast text.
    ///
    /// - Parameters:
    ///   - key: The localization key.
    ///   - defaultValue: The English source value.
    ///   - bundle: The bundle that owns the string catalog.
    ///   - comment: Context for translators.
    /// - Returns: Localized toast text.
    public static func localized(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        bundle: Bundle = .main,
        comment: StaticString? = nil
    ) -> Self {
        .localized(
            LocalizedStringResource(
                key,
                defaultValue: defaultValue,
                bundle: bundle,
                comment: comment
            )
        )
    }

    var text: Text {
        switch self {
        case .localized(let resource):
            Text(resource)
        case .verbatim(let value):
            Text(verbatim: value)
        }
    }

    var resolvedValue: String {
        switch self {
        case .localized(let resource):
            String(localized: resource)
        case .verbatim(let value):
            value
        }
    }
}
