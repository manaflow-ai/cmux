#if os(iOS)
import SwiftUI

/// The single storage-backed feature-flag seam for the DEBUG diff viewer.
struct MobileDiffViewerFeature: DynamicProperty {
    @AppStorage("cmux.mobile.debug.diffViewerChangesEnabled") var isEnabled = true
}
#endif
