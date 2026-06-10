import AppKit
import ObjectiveC
#if DEBUG
import Bonsplit
#endif

@MainActor
final class WindowTerminalPortal: NSObject {
#if DEBUG
    static var isPointerDragActiveForTesting = false
#endif
    static let tinyHideThreshold: CGFloat = 1
    static let minimumRevealWidth: CGFloat = 24
    static let minimumRevealHeight: CGFloat = 18
    static let transientRecoveryRetryBudget: Int = 12
#if CMUX_ISSUE_483_PORTAL_RECOVERY
    static let transientRecoveryEnabled = true
#else
    static let transientRecoveryEnabled = false
#endif

    weak var window: NSWindow?
    let hostView = WindowTerminalHostView(frame: .zero)
    let dividerOverlayView = SplitDividerOverlayView(frame: .zero)
    weak var installedContainerView: NSView?
    weak var installedReferenceView: NSView?
    var installConstraints: [NSLayoutConstraint] = []
    var hasDeferredFullSyncScheduled = false
    var hasExternalGeometrySyncScheduled = false
    var pendingExternalGeometrySyncRequiresImmediate = false
    var externalGeometrySyncGeneration: UInt64 = 0
    var geometryObservers: [NSObjectProtocol] = []
#if DEBUG
    var lastLoggedBonsplitContainerSignature: String?
#endif

    struct Entry {
        weak var hostedView: GhosttySurfaceScrollView?
        weak var anchorView: NSView?
        var visibleInUI: Bool
        var zPriority: Int
        var transientRecoveryRetriesRemaining: Int
    }

    var entriesByHostedId: [ObjectIdentifier: Entry] = [:]
    var hostedByAnchorId: [ObjectIdentifier: ObjectIdentifier] = [:]

    init(window: NSWindow, syncLayout: Bool = true) {
        self.window = window
        super.init()
        hostView.wantsLayer = true
        hostView.layer?.masksToBounds = true
        hostView.postsFrameChangedNotifications = true
        hostView.postsBoundsChangedNotifications = true
        hostView.translatesAutoresizingMaskIntoConstraints = false
        dividerOverlayView.translatesAutoresizingMaskIntoConstraints = true
        dividerOverlayView.autoresizingMask = [.width, .height]
        installGeometryObservers(for: window)
        _ = ensureInstalled(syncLayout: syncLayout)
    }

#if DEBUG
    struct DebugStats {
        let windowNumber: Int
        let entryCount: Int
        let hostSubviewCount: Int
        let terminalSubviewCount: Int
        let mappedTerminalSubviewCount: Int
        let orphanTerminalSubviewCount: Int
        let visibleOrphanTerminalSubviewCount: Int
        let staleEntryCount: Int
        let visibleInvalidAnchorEntryCount: Int
    }

    func debugStats() -> DebugStats {
        let terminalSubviews = hostView.subviews.compactMap { $0 as? GhosttySurfaceScrollView }
        var mappedTerminalSubviewCount = 0
        var orphanTerminalSubviewCount = 0
        var visibleOrphanTerminalSubviewCount = 0
        var visibleInvalidAnchorEntryCount = 0

        for hostedView in terminalSubviews {
            let hostedId = ObjectIdentifier(hostedView)
            if entriesByHostedId[hostedId] != nil {
                mappedTerminalSubviewCount += 1
            } else {
                orphanTerminalSubviewCount += 1
                if hostedView.window != nil,
                   !hostedView.isHidden,
                   hostedView.frame.width > Self.tinyHideThreshold,
                   hostedView.frame.height > Self.tinyHideThreshold {
                    visibleOrphanTerminalSubviewCount += 1
                }
            }
        }

        for entry in entriesByHostedId.values where entry.visibleInUI {
            guard let anchor = entry.anchorView else {
                visibleInvalidAnchorEntryCount += 1
                continue
            }
            let anchorInvalidForCurrentHost =
                anchor.window !== window ||
                anchor.superview == nil ||
                (installedReferenceView.map { !anchor.isDescendant(of: $0) } ?? false)
            if anchorInvalidForCurrentHost {
                visibleInvalidAnchorEntryCount += 1
            }
        }

        let staleEntryCount = entriesByHostedId.values.reduce(0) { partialResult, entry in
            guard let hostedView = entry.hostedView else { return partialResult + 1 }
            return hostedView.superview === hostView ? partialResult : partialResult + 1
        }

        return DebugStats(
            windowNumber: window?.windowNumber ?? -1,
            entryCount: entriesByHostedId.count,
            hostSubviewCount: hostView.subviews.count,
            terminalSubviewCount: terminalSubviews.count,
            mappedTerminalSubviewCount: mappedTerminalSubviewCount,
            orphanTerminalSubviewCount: orphanTerminalSubviewCount,
            visibleOrphanTerminalSubviewCount: visibleOrphanTerminalSubviewCount,
            staleEntryCount: staleEntryCount,
            visibleInvalidAnchorEntryCount: visibleInvalidAnchorEntryCount
        )
    }

    func debugEntryCount() -> Int {
        entriesByHostedId.count
    }

    func debugHostedSubviewCount() -> Int {
        hostView.subviews.count
    }
#endif

}

