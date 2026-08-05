import CmuxSettings
import CmuxWorkspaces
import CoreGraphics
import Foundation

enum MainWindowSidebarWidthPolicy {
    static let maximumLeftWidthRatio: CGFloat = 1.0 / 3.0
    static let minimumRightWidth = CGFloat(RightSidebarWidthSettings.minimumWidth)
    static let maximumRightWidth = CGFloat(RightSidebarWidthSettings.builtInMaximumWidth)
    static let minimumTerminalWidthWithRightSidebar: CGFloat = 360

    static func maximumLeftWidth(availableWidth: CGFloat, minimumWidth: CGFloat) -> CGFloat {
        let available = availableWidth.isFinite && availableWidth > 0 ? availableWidth : 1920
        return max(minimumWidth, available * maximumLeftWidthRatio)
    }

    static func clampedLeftWidth(
        _ candidate: CGFloat,
        maximumWidth: CGFloat,
        minimumWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultMinimumSidebarWidth)
    ) -> CGFloat {
        let sanitizedMaximum = max(minimumWidth, maximumWidth.isFinite ? maximumWidth : minimumWidth)
        let value = candidate.isFinite ? candidate : CGFloat(SessionPersistencePolicy.defaultSidebarWidth)
        return max(minimumWidth, min(sanitizedMaximum, value))
    }

    static func resolvedLeftWidth(
        _ candidate: CGFloat,
        availableWidth: CGFloat,
        defaults: UserDefaults = .standard
    ) -> CGFloat {
        let storedMinimum = defaults.double(forKey: SessionPersistencePolicy.sidebarMinimumWidthKey)
        let requestedMinimum = storedMinimum > 0
            ? storedMinimum
            : SessionPersistencePolicy.defaultMinimumSidebarWidth
        let minimum = CGFloat(SessionPersistencePolicy.sanitizedMinimumSidebarWidth(requestedMinimum))
        return clampedLeftWidth(
            candidate,
            maximumWidth: maximumLeftWidth(availableWidth: availableWidth, minimumWidth: minimum),
            minimumWidth: minimum
        )
    }

    static func clampedRightWidth(
        _ candidate: CGFloat,
        availableWidth: CGFloat,
        configuredMaximumWidth: CGFloat? = nil
    ) -> CGFloat {
        let available = availableWidth.isFinite && availableWidth > 0 ? availableWidth : 1920
        let availableCap = max(minimumRightWidth, available - minimumTerminalWidthWithRightSidebar)
        let configuredCap: CGFloat
        if let configuredMaximumWidth, configuredMaximumWidth.isFinite {
            configuredCap = max(minimumRightWidth, configuredMaximumWidth)
        } else {
            configuredCap = maximumRightWidth
        }
        let maximum = min(configuredCap, availableCap)
        let value = candidate.isFinite ? candidate : 220
        return max(minimumRightWidth, min(maximum, value))
    }

    static func resolvedRightWidth(
        _ candidate: CGFloat,
        availableWidth: CGFloat,
        defaults: UserDefaults = .standard
    ) -> CGFloat {
        let storedMaximum = defaults.double(forKey: RightSidebarWidthSettings.maxWidthKey)
        let configuredMaximum = RightSidebarWidthSettings()
            .configuredMaximumWidth(from: storedMaximum)
            .map { CGFloat($0) }
        return clampedRightWidth(
            candidate,
            availableWidth: availableWidth,
            configuredMaximumWidth: configuredMaximum
        )
    }
}
