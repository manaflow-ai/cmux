public import AppKit
public import Foundation

/// Decides whether a sidebar row's shortcut-hint visibility should use the
/// frozen value captured for a specific tab, or fall back to the live value.
public struct SidebarShortcutHintFreezePolicy {
    public init() {}

    public func resolved(
        live: Bool,
        currentTabId: UUID,
        frozenTabId: UUID?,
        frozenValue: Bool
    ) -> Bool {
        if frozenTabId == currentTabId {
            return frozenValue
        }
        return live
    }
}

/// Whether an in-flight sidebar drag should be reset when a drop lands outside
/// the sidebar.
public struct SidebarOutsideDropResetPolicy {
    public init() {}

    public func shouldResetDrag(draggedTabId: UUID?, hasSidebarDragPayload: Bool) -> Bool {
        draggedTabId != nil && hasSidebarDragPayload
    }
}

/// Failsafe rules for clearing a stuck sidebar drag (mouse released outside a
/// drop target, app resigned active, escape pressed).
public struct SidebarDragFailsafePolicy {
    public static let clearDelay: TimeInterval = 0.15

    public init() {}

    public func shouldRequestClear(isDragActive: Bool, isLeftMouseButtonDown: Bool) -> Bool {
        isDragActive && !isLeftMouseButtonDown
    }

    public func shouldRequestClearWhenMonitoringStarts(isLeftMouseButtonDown: Bool) -> Bool {
        shouldRequestClear(
            isDragActive: true,
            isLeftMouseButtonDown: isLeftMouseButtonDown
        )
    }

    public func shouldRequestClear(forMouseEventType eventType: NSEvent.EventType) -> Bool {
        eventType == .leftMouseUp
    }
}
