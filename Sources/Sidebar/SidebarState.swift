import Combine
import CoreGraphics
import AppKit

@MainActor
enum PortalGeometrySyncUrgency {
    private struct Request {
        weak var window: NSWindow?
        let windowID: ObjectIdentifier
        let generation: UInt64

        func matches(_ candidate: NSWindow?) -> Bool {
            guard let window, let candidate else { return false }
            return window === candidate && ObjectIdentifier(candidate) == windowID
        }
    }

    private static var immediateExternalGeometrySyncRequest: Request?
    private static var immediateExternalGeometrySyncGeneration: UInt64 = 0

    static func shouldSynchronizeNextExternalGeometryChangeImmediately(for window: NSWindow?) -> Bool {
        guard let request = immediateExternalGeometrySyncRequest else { return false }
        if request.window == nil {
            immediateExternalGeometrySyncRequest = nil
            return false
        }
        return request.matches(window)
    }

    static func requestImmediateExternalGeometrySyncForNextLayoutPass(in window: NSWindow?) {
        guard let window else {
            immediateExternalGeometrySyncRequest = nil
            return
        }
        immediateExternalGeometrySyncGeneration &+= 1
        immediateExternalGeometrySyncRequest = Request(
            window: window,
            windowID: ObjectIdentifier(window),
            generation: immediateExternalGeometrySyncGeneration
        )
    }

    static func noteImmediateExternalGeometrySyncUsed(for window: NSWindow?) {
        guard let request = immediateExternalGeometrySyncRequest,
              request.matches(window) else { return }
        immediateExternalGeometrySyncRequest = nil
    }

    static func clearImmediateExternalGeometrySyncIfUnconsumed(for window: NSWindow?) {
        guard let request = immediateExternalGeometrySyncRequest,
              request.matches(window) else { return }
        let generation = request.generation
        Task { @MainActor [weak window] in
            guard let current = immediateExternalGeometrySyncRequest,
                  current.generation == generation,
                  current.matches(window) else { return }
            immediateExternalGeometrySyncRequest = nil
        }
    }

#if DEBUG
    static func resetForTesting() {
        immediateExternalGeometrySyncRequest = nil
        immediateExternalGeometrySyncGeneration = 0
    }
#endif
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
