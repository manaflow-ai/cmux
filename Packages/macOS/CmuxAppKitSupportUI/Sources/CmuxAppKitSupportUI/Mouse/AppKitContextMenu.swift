public import AppKit
public import SwiftUI

// MARK: - Value model

/// A single item in an AppKit-backed context menu.
///
/// Holds value-typed presentation data plus a `@MainActor` action closure, so a
/// row can describe its menu with immutable snapshots and closures only. This
/// keeps adopters compatible with the snapshot-boundary / `Equatable` row
/// contracts used by churny list views.
public struct CmuxContextMenuItem {
    public let title: String
    public let systemImage: String?
    public let isEnabled: Bool
    public let action: @MainActor () -> Void

    public init(
        title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// One element of an AppKit-backed context menu: a button-style item or a
/// separator. Mirrors the small subset of SwiftUI `Button` / `Divider` that the
/// migrated row menus actually use.
public enum CmuxContextMenuElement {
    case item(CmuxContextMenuItem)
    case separator

    /// Convenience constructor for a button-style menu item.
    public static func button(
        _ title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) -> CmuxContextMenuElement {
        .item(
            CmuxContextMenuItem(
                title: title,
                systemImage: systemImage,
                isEnabled: isEnabled,
                action: action
            )
        )
    }
}

// MARK: - Action dispatch

/// Retains a menu item's action closure and exposes it to the Objective-C
/// target/action mechanism. `NSMenuItem.target` is a *weak* reference, so the
/// owning ``CmuxContextMenu`` keeps these targets alive for the menu's lifetime.
@MainActor
public final class CmuxContextMenuActionTarget: NSObject {
    private let handler: @MainActor () -> Void

    public init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init()
    }

    @objc public func invoke(_ sender: Any?) {
        handler()
    }
}

// MARK: - NSMenu builder

/// An `NSMenu` built on demand from ``CmuxContextMenuElement`` values.
///
/// This is the cmux-side replacement for SwiftUI's `.contextMenu` on high-churn
/// list rows. SwiftUI's `.contextMenu` modifier leaks a
/// `ContextMenuResponder ⇄ AppKitMenuDelegate` pair per attachment
/// (https://github.com/manaflow-ai/cmux/issues/5953); building a plain `NSMenu`
/// only when the user right-clicks avoids creating that responder at all.
public final class CmuxContextMenu: NSMenu {
    /// Strong references to the action targets, since `NSMenuItem.target` is weak.
    private var actionTargets: [CmuxContextMenuActionTarget] = []

    /// Builds an `NSMenu` from the supplied elements. Pure and synchronous so it
    /// can be unit-tested without presenting any UI.
    @MainActor
    public static func make(from elements: [CmuxContextMenuElement]) -> CmuxContextMenu {
        let menu = CmuxContextMenu()
        // Honor each item's `isEnabled` exactly instead of letting AppKit
        // auto-enable/disable based on responder-chain action resolution.
        menu.autoenablesItems = false

        for element in elements {
            switch element {
            case .separator:
                menu.addItem(.separator())
            case .item(let item):
                let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                menuItem.isEnabled = item.isEnabled
                if let systemImage = item.systemImage {
                    menuItem.image = NSImage(
                        systemSymbolName: systemImage,
                        accessibilityDescription: nil
                    )
                }
                if item.isEnabled {
                    let target = CmuxContextMenuActionTarget(handler: item.action)
                    menuItem.target = target
                    menuItem.action = #selector(CmuxContextMenuActionTarget.invoke(_:))
                    menu.actionTargets.append(target)
                }
                menu.addItem(menuItem)
            }
        }

        return menu
    }
}

// MARK: - Right-click capture view

/// Backing `NSView` for ``AppKitContextMenuCapture`` that hit-tests only
/// right-clicks and control-clicks, presenting an AppKit ``CmuxContextMenu`` on
/// demand. Left-click selection, drags, double-taps, and hover continue to
/// hit-test through to the underlying SwiftUI view tree — the same technique as
/// `MiddleClickCaptureView`.
public final class AppKitContextMenuCaptureView: NSView {
    /// Builds the menu elements on demand (each right-click), so the menu always
    /// reflects current state and no responder is retained between invocations.
    public var elementsProvider: (@MainActor () -> [CmuxContextMenuElement])?

    public override func hitTest(_ point: NSPoint) -> NSView? {
        // Only claim contextual-menu events; everything else passes through so
        // SwiftUI gestures (tap, drag, hover) keep working unchanged.
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown:
            return self
        case .leftMouseDown where event.modifierFlags.contains(.control):
            return self
        default:
            return nil
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        presentMenu(for: event)
    }

    public override func mouseDown(with event: NSEvent) {
        // control-click is the macOS contextual-menu gesture; everything else
        // should never reach here because `hitTest` only claims those events.
        guard event.modifierFlags.contains(.control) else {
            super.mouseDown(with: event)
            return
        }
        presentMenu(for: event)
    }

    private func presentMenu(for event: NSEvent) {
        guard let elements = elementsProvider?(), !elements.isEmpty else { return }
        let menu = CmuxContextMenu.make(from: elements)
        guard !menu.items.isEmpty else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

// MARK: - SwiftUI bridge

/// A transparent overlay that presents an AppKit context menu on right-click /
/// control-click, avoiding SwiftUI's leaky `.contextMenu` bridge.
public struct AppKitContextMenuCapture: NSViewRepresentable {
    public let elements: @MainActor () -> [CmuxContextMenuElement]

    public init(elements: @escaping @MainActor () -> [CmuxContextMenuElement]) {
        self.elements = elements
    }

    public func makeNSView(context: Context) -> AppKitContextMenuCaptureView {
        let view = AppKitContextMenuCaptureView()
        view.elementsProvider = elements
        return view
    }

    public func updateNSView(_ nsView: AppKitContextMenuCaptureView, context: Context) {
        nsView.elementsProvider = elements
    }
}

extension View {
    /// Attaches an AppKit `NSMenu`-backed context menu instead of SwiftUI's
    /// `.contextMenu`.
    ///
    /// Use this on high-churn list rows (created/destroyed as data changes) to
    /// avoid the per-attachment SwiftUI `ContextMenuResponder` retain cycle
    /// (https://github.com/manaflow-ai/cmux/issues/5953). The `elements` closure
    /// is invoked fresh on each right-click, so it should capture model state
    /// above the row's snapshot boundary and return value-typed elements only.
    public func cmuxAppKitContextMenu(
        _ elements: @escaping @MainActor () -> [CmuxContextMenuElement]
    ) -> some View {
        overlay(AppKitContextMenuCapture(elements: elements))
    }
}
