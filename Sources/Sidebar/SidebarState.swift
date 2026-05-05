import Combine
import CoreGraphics
import Foundation

@MainActor
enum PortalGeometrySyncUrgency {
    private static var immediateExternalGeometrySyncRequested = false, immediateExternalGeometrySyncGeneration: UInt64 = 0
    static var shouldSynchronizeNextExternalGeometryChangeImmediately: Bool { immediateExternalGeometrySyncRequested }
    static func requestImmediateExternalGeometrySyncForNextLayoutPass() { immediateExternalGeometrySyncRequested = true; immediateExternalGeometrySyncGeneration &+= 1 }
    static func noteImmediateExternalGeometrySyncUsed() {
        let generation = immediateExternalGeometrySyncGeneration
        DispatchQueue.main.async { if immediateExternalGeometrySyncGeneration == generation { immediateExternalGeometrySyncRequested = false } }
    }
}

final class SidebarState: ObservableObject {
    @Published private(set) var portalGeometrySyncRevision: UInt64 = 0
    @Published private(set) var isVisible: Bool
    @Published var persistedWidth: CGFloat

    init(isVisible: Bool = true, persistedWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultSidebarWidth)) {
        self.isVisible = isVisible
        let sanitized = SessionPersistencePolicy.sanitizedSidebarWidth(Double(persistedWidth))
        self.persistedWidth = CGFloat(sanitized)
    }

    func toggle() {
        setVisible(!isVisible)
    }

    func setVisible(_ nextValue: Bool) {
        guard isVisible != nextValue else { return }
        isVisible = nextValue
        portalGeometrySyncRevision &+= 1
    }
}

enum SidebarResizeInteraction {
    enum Edge {
        case leading
        case trailing

        private var hitWidthBeforeDivider: CGFloat {
            switch self {
            case .leading:
                return SidebarResizeInteraction.sidebarSideHitWidth
            case .trailing:
                return SidebarResizeInteraction.contentSideHitWidth
            }
        }

        func handleX(dividerX: CGFloat) -> CGFloat {
            dividerX - hitWidthBeforeDivider
        }

        func hitRange(dividerX: CGFloat) -> ClosedRange<CGFloat> {
            let minX = handleX(dividerX: dividerX)
            return minX...(minX + SidebarResizeInteraction.totalHitWidth)
        }
    }

    // Keep a generous drag target inside the sidebar itself, but keep overlap
    // into terminal/browser content small so edge text selection still wins.
    static let sidebarSideHitWidth: CGFloat = 6
    // 4 pt matches the 4 pt padding used in GhosttySurfaceScrollView drop zone overlays
    // (dropZoneOverlayFrame). This prevents column-0 text near the leading edge from
    // accidentally triggering the sidebar resize when interacting with leftmost content.
    static let contentSideHitWidth: CGFloat = 4

    static var totalHitWidth: CGFloat {
        sidebarSideHitWidth + contentSideHitWidth
    }
}
