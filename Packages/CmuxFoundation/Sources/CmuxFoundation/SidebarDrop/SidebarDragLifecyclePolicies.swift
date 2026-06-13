public import AppKit
public import Foundation

/// Decides whether a sidebar row's shortcut-hint visibility should use the
/// frozen value captured for a specific tab, or fall back to the live value.
public enum SidebarShortcutHintFreezePolicy {
    public static func resolved(
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
public enum SidebarOutsideDropResetPolicy {
    public static func shouldResetDrag(draggedTabId: UUID?, hasSidebarDragPayload: Bool) -> Bool {
        draggedTabId != nil && hasSidebarDragPayload
    }
}

/// Failsafe rules for clearing a stuck sidebar drag (mouse released outside a
/// drop target, app resigned active, escape pressed).
public enum SidebarDragFailsafePolicy {
    public static let clearDelay: TimeInterval = 0.15

    public static func shouldRequestClear(isDragActive: Bool, isLeftMouseButtonDown: Bool) -> Bool {
        isDragActive && !isLeftMouseButtonDown
    }

    public static func shouldRequestClearWhenMonitoringStarts(isLeftMouseButtonDown: Bool) -> Bool {
        shouldRequestClear(
            isDragActive: true,
            isLeftMouseButtonDown: isLeftMouseButtonDown
        )
    }

    public static func shouldRequestClear(forMouseEventType eventType: NSEvent.EventType) -> Bool {
        eventType == .leftMouseUp
    }
}
