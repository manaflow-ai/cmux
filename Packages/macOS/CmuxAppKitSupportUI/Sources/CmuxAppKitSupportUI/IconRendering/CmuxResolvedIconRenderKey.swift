import AppKit

/// Identity of one icon render request under one effective appearance.
struct CmuxResolvedIconRenderKey {
    private let source: CmuxResolvedIconSourceKey
    private let width: CGFloat
    private let height: CGFloat
    private let tint: NSColor?
    private let symbolWeight: CGFloat
    private let appearanceName: NSAppearance.Name
    private let appearanceIdentity: ObjectIdentifier
    let appearance: NSAppearance
    let assetBundle: Bundle?

    private func tintMatches(_ other: NSColor?) -> Bool {
        switch (tint, other) {
        case (.none, .none):
            return true
        case let (tint?, other?):
            return tint.isEqual(other)
        default:
            return false
        }
    }

    func matchesAssetBundle(_ other: Bundle?) -> Bool {
        switch (assetBundle, other) {
        case (.none, .none):
            return true
        case let (assetBundle?, other?):
            return assetBundle === other
        default:
            return false
        }
    }

    init(request: CmuxResolvedIconRequest, appearance: NSAppearance) {
        source = CmuxResolvedIconSourceKey(request.source)
        width = request.size.width
        height = request.size.height
        tint = request.tintColor
        symbolWeight = request.symbolWeight.rawValue
        appearanceName = appearance.name
        appearanceIdentity = ObjectIdentifier(appearance)
        self.appearance = appearance
        if case .asset(_, let bundle) = request.source {
            assetBundle = bundle
        } else {
            assetBundle = nil
        }
    }

    func shouldSkipRender(for other: CmuxResolvedIconRenderKey) -> Bool {
        source.canReuseRenderedImage &&
            other.source.canReuseRenderedImage &&
            matchesRequestAndAppearance(other)
    }

    func matchesRequestAndAppearance(_ other: CmuxResolvedIconRenderKey) -> Bool {
        source == other.source &&
            width == other.width &&
            height == other.height &&
            symbolWeight == other.symbolWeight &&
            appearanceName == other.appearanceName &&
            appearanceIdentity == other.appearanceIdentity &&
            tintMatches(other.tint)
    }

    func shouldSkipBlankRetry(for other: CmuxResolvedIconRenderKey) -> Bool {
        shouldSkipRender(for: other)
    }

    var reusableKey: CmuxResolvedIconReusableRenderKey? {
        guard source.canReuseRenderedImage else { return nil }
        return CmuxResolvedIconReusableRenderKey(
            source: source,
            width: width,
            height: height,
            tint: tint,
            symbolWeight: symbolWeight,
            appearanceName: appearanceName,
            appearanceIdentity: appearanceIdentity
        )
    }

}
