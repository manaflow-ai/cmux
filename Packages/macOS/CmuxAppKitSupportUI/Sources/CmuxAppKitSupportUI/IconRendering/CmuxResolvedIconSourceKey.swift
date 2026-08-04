import AppKit

/// Stable source identity used to compare icon render requests.
enum CmuxResolvedIconSourceKey: Hashable {
    case systemSymbol(name: String, accessibilityDescription: String?)
    case asset(name: String, bundle: ObjectIdentifier)
    case image(ObjectIdentifier)

    init(_ source: CmuxResolvedIconSource) {
        switch source {
        case .systemSymbol(let name, let accessibilityDescription):
            self = .systemSymbol(name: name, accessibilityDescription: accessibilityDescription)
        case .asset(let name, let bundle):
            self = .asset(name: name, bundle: ObjectIdentifier(bundle))
        case .image(let image):
            self = .image(ObjectIdentifier(image))
        }
    }

    var canReuseRenderedImage: Bool {
        switch self {
        case .systemSymbol, .asset:
            return true
        case .image:
            return false
        }
    }
}
