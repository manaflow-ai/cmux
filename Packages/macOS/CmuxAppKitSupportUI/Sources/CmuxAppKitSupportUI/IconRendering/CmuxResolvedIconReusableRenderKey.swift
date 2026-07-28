import AppKit

/// Hashable subset of a render key that can safely share a cached raster.
struct CmuxResolvedIconReusableRenderKey: Hashable {
    let source: CmuxResolvedIconSourceKey
    let width: CGFloat
    let height: CGFloat
    let tint: NSColor?
    let symbolWeight: CGFloat
    let appearanceName: NSAppearance.Name
    let appearanceIdentity: ObjectIdentifier
}
