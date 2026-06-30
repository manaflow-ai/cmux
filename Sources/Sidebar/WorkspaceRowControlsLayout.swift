import CmuxSettings
import CoreGraphics

struct WorkspaceRowControlsLayout: Equatable {
    private static let baseMinimumSidebarWidth: CGFloat = 220
    private static let baseControlHitSize: CGFloat = 16
    private static let baseControlSpacing: CGFloat = 4

    let controlCount: Int
    let fontScale: CGFloat

    var controlHitSize: CGFloat {
        max(Self.baseControlHitSize, Self.baseControlHitSize * fontScale)
    }

    var controlSpacing: CGFloat {
        max(Self.baseControlSpacing, Self.baseControlSpacing * fontScale)
    }

    var trailingWidth: CGFloat {
        guard controlCount > 0 else { return 0 }
        return CGFloat(controlCount) * controlHitSize + CGFloat(controlCount - 1) * controlSpacing
    }

    var minimumSidebarWidth: CGFloat {
        Self.requiredMinimumSidebarWidth(controlCount: controlCount, fontScale: fontScale)
    }

    static func requiredMinimumSidebarWidth(controlCount: Int, fontScale: CGFloat) -> CGFloat {
        Self.baseMinimumSidebarWidth
    }
}
