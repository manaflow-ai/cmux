import Foundation

/// The kind of artifact a ``TargetSummary`` produces.
///
/// Modeled after Xcode's `productType` field on `PBXNativeTarget`. Adapters
/// for other ecosystems map their native target kinds (Cargo `lib`/`bin`,
/// Gradle `application`/`library`/`androidTest`, npm `app`/`lib`) into this
/// enum, falling back to ``other`` when no direct mapping exists.
public enum TargetProductType: String, Sendable, Hashable, Codable {
    case application
    case framework
    case staticLibrary
    case dynamicLibrary
    case bundle
    case unitTest
    case uiTest
    case commandLineTool
    case appExtension
    case watchApp
    case watchExtension
    case xcFramework
    case other

    /// Parse the raw Xcode product-type string into a ``TargetProductType``.
    ///
    /// Returns ``other`` when the value is not recognized so the UI can still
    /// render a target row instead of failing the whole load.
    public static func fromXcodeProductType(_ raw: String) -> TargetProductType {
        switch raw {
        case "com.apple.product-type.application":
            return .application
        case "com.apple.product-type.framework":
            return .framework
        case "com.apple.product-type.library.static":
            return .staticLibrary
        case "com.apple.product-type.library.dynamic":
            return .dynamicLibrary
        case "com.apple.product-type.bundle":
            return .bundle
        case "com.apple.product-type.bundle.unit-test":
            return .unitTest
        case "com.apple.product-type.bundle.ui-testing":
            return .uiTest
        case "com.apple.product-type.tool":
            return .commandLineTool
        case "com.apple.product-type.app-extension":
            return .appExtension
        case "com.apple.product-type.application.watchapp",
             "com.apple.product-type.application.watchapp2":
            return .watchApp
        case "com.apple.product-type.watchkit-extension",
             "com.apple.product-type.watchkit2-extension":
            return .watchExtension
        case "com.apple.product-type.xcframework":
            return .xcFramework
        default:
            return .other
        }
    }
}
