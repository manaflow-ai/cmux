#if DEBUG && os(iOS)
import CmuxMobileDesign
import SwiftUI

/// The production context ring and popover, opened by the capture's real tap.
/// Nil preserves the original native popover for the before comparison.
public struct ContextUsageMaterialGallery: View {
    private let material: CmuxMobileTransientMaterial?

    public init(material: CmuxMobileTransientMaterial?) { self.material = material }

    public var body: some View {
        ContextUsageRing(usage: ContextUsage(used: 111_000, size: 475_000), material: material)
    }
}
#endif
