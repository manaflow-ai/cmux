import CMUXMobileCore
import Foundation

@MainActor
final class BrowserPreviewSurfaceState {
    var continuations: [UUID: AsyncStream<MobileBrowserPreviewFrame>.Continuation] = [:]
    var resolutions: [UUID: MobileBrowserPreviewResolution] = [:]
    var latestFrame: MobileBrowserPreviewFrame?

    var requestedResolution: MobileBrowserPreviewResolution {
        resolutions.values.contains(.full) ? .full : .preview
    }
}
