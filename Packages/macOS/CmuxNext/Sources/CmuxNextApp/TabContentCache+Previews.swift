import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextTerminal
import CoreGraphics

/// Hover card and drag thumbnails of `TabContentCache` tabs.
extension TabContentCache {
    func previewImage(for key: String, maxPixelSize: CGSize) async -> CGImage? {
        if let entry = terminals[key],
           let image = await entry.session.snapshotInBackground(maxPixelSize: max(maxPixelSize.width, maxPixelSize.height)) {
            previews.insert(image, for: key)
            return image
        }
        if let entry = browsers[key], let image = try? await entry.tab.snapshot() {
            return await TabPreviewFitting.fit(image, maxPixelSize)
        }
        return previews.image(for: key)
    }
}
