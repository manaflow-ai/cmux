#if os(iOS) && DEBUG
import UIKit

@MainActor
enum MobileReleaseGateUISnapshot {
    /// Supporting evidence from the actual isolated app window, captured after
    /// the measured boundary. Each name is overwritten, so storage is bounded.
    static func capture(_ window: UIWindow?, name: String) {
        guard let window, !window.isHidden, !window.bounds.isEmpty else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let data = image.pngData(),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let destination = caches.appendingPathComponent("cmux-iroh-ui-\(name).png")
        Task.detached(priority: .utility) {
            try? data.write(to: destination, options: .atomic)
        }
    }
}
#endif
