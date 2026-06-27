import CoreGraphics
import Foundation

struct BrowserPageZoomPreference {
    static let storageKey = "browserLastPageZoom"
    static let defaultZoom: CGFloat = 1.0
    static let minimumZoom: CGFloat = 0.25
    static let maximumZoom: CGFloat = 5.0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func currentZoom() -> CGFloat {
        guard let rawValue = defaults.object(forKey: Self.storageKey) else {
            return Self.defaultZoom
        }
        guard let number = rawValue as? NSNumber else {
            return Self.defaultZoom
        }
        return Self.clampedZoom(CGFloat(number.doubleValue))
    }

    @discardableResult
    func normalizeStoredZoom() -> CGFloat {
        guard let rawValue = defaults.object(forKey: Self.storageKey) else {
            return Self.defaultZoom
        }
        let zoom = currentZoom()
        guard let number = rawValue as? NSNumber else {
            defaults.set(Double(zoom), forKey: Self.storageKey)
            return zoom
        }
        let rawZoom = CGFloat(number.doubleValue)
        if !rawZoom.isFinite || abs(rawZoom - zoom) >= 0.0001 {
            defaults.set(Double(zoom), forKey: Self.storageKey)
        }
        return zoom
    }

    func save(_ zoom: CGFloat) {
        defaults.set(Double(Self.clampedZoom(zoom)), forKey: Self.storageKey)
    }

    static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return Self.defaultZoom }
        return max(Self.minimumZoom, min(Self.maximumZoom, zoom))
    }
}
