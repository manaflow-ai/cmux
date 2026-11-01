#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

/// Every click target of a window and whether one press on it acts now (`debug.first_click`,
/// scripts/cmux-next/first-click-live.py). DEBUG and bench builds only.
///
/// A target is a visible control (`NSControl`, but not a label), a view that handles `mouseDown:`
/// itself, or a SwiftUI hosting view. For each it records whether a press at the center of its
/// visible part reaches it (a transparent sibling or an overlay above it takes the press otherwise),
/// its own `acceptsFirstMouse(for:)` answer, and whether ``FirstClickPolicy`` takes a press in the
/// window now.
///
/// ```swift
/// let report = FirstClickAudit().report(window, keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow,
///                                      appIsActive: NSApp.isActive, appIsModal: NSApp.modalWindow != nil)
/// let dropped = report.targets.filter { $0.reachesTarget && !$0.actsOnFirstClick }
/// ```
@MainActor
public struct FirstClickAudit {
    /// One click target.
    public struct Target: Sendable, Equatable {
        /// The view's class name.
        public let className: String
        /// Its accessibility label, else a button's title, else empty.
        public let label: String
        /// The center of its visible part, in top-left window points (as `debug.mouse` takes them).
        public let center: CGPoint
        /// A press at ``center`` reaches this view or one inside it.
        public let reachesTarget: Bool
        /// The class of the view a press at ``center`` reaches.
        public let hitClassName: String?
        /// The answer of the view a press reaches to `acceptsFirstMouse(for:)`.
        public let acceptsFirstMouse: Bool
        /// The control is enabled (true for a view that is not a control).
        public let isEnabled: Bool
        /// One press acts now: the window policy takes it, or the view accepts the first mouse.
        public let actsOnFirstClick: Bool
    }

    /// Who holds the key, seen from the audited window.
    public enum KeyHolder: String, Sendable {
        /// The audited window.
        case window = "self"
        /// One of its child windows at any depth (a Chromium page).
        case page
        /// A panel of another window or of none.
        case panel
        /// Another top-level window.
        case other
        /// No window.
        case none
    }

    /// The audit of one window.
    public struct Report: Sendable {
        /// Who holds the key.
        public let keyHolder: KeyHolder
        /// The key window's class name.
        public let keyClassName: String?
        /// ``FirstClickPolicy`` takes a press in the window now.
        public let policyTakesPress: Bool
        /// Every click target, in view-tree order.
        public let targets: [Target]
    }

    /// Makes the audit; it holds no state.
    public init() {}

    /// Audits `window`.
    ///
    /// - Parameter window: The window to audit.
    /// - Parameter keyWindow: The app's key window.
    /// - Parameter mainWindow: The app's main window.
    /// - Parameter appIsActive: Whether the app is active.
    /// - Parameter appIsModal: Whether a modal session runs.
    /// - Returns: Who holds the key, the policy's answer and every click target.
    public func report(_ window: NSWindow, keyWindow: NSWindow?, mainWindow: NSWindow?, appIsActive: Bool, appIsModal: Bool) -> Report {
        let policy = FirstClickPolicy().takesFirstClick(type: .leftMouseDown, modifiers: [], in: window, keyWindow: keyWindow,
                                                        mainWindow: mainWindow, appIsActive: appIsActive, appIsModal: appIsModal)
        var targets: [Target] = []
        if let frameView = window.contentView?.superview {
            let baseMouseDown = NSView.instanceMethod(for: #selector(NSView.mouseDown(with:)))
            visit(frameView) { view in
                guard isTarget(view, baseMouseDown: baseMouseDown), !view.isHiddenOrHasHiddenAncestor else { return }
                let visible = view.visibleRect.intersection(view.bounds)
                guard visible.width >= 2, visible.height >= 2 else { return }
                targets.append(target(view, visible: visible, frameView: frameView, window: window, policy: policy))
            }
        }
        return Report(keyHolder: holder(keyWindow, for: window), keyClassName: keyWindow.map { String(describing: type(of: $0)) },
                      policyTakesPress: policy, targets: targets)
    }

    /// The `debug.first_click` reply for `window`, as a `JSONSerialization` object graph.
    ///
    /// - Parameter window: The window to audit.
    /// - Parameter makePageKey: First give the key to the window's frontmost visible Chromium page
    ///   window (``WindowOverlayHost/isPageWindow(_:)``), as a click in the page does.
    /// - Returns: `app_active`, `key`, `key_class`, `policy` and `targets` (each target's `class`,
    ///   `label`, `x`, `y`, `hit`, `hit_class`, `accepts`, `enabled` and `first_click`), or `error`
    ///   when `makePageKey` found no page window that takes the key.
    public func debugReply(_ window: NSWindow, makePageKey: Bool) -> [String: Any] {
        if makePageKey {
            let pages = (window.childWindows ?? []).filter { WindowOverlayHost.isPageWindow($0) && $0.isVisible && $0.canBecomeKey }
            guard let page = pages.last else { return ["error": "the window shows no Chromium page window that takes the key"] }
            page.makeKey()
        }
        let report = report(window, keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow, appIsActive: NSApp.isActive,
                            appIsModal: NSApp.modalWindow != nil)
        let targets: [[String: Any]] = report.targets.map {
            ["class": $0.className, "label": $0.label, "x": Double($0.center.x), "y": Double($0.center.y), "hit": $0.reachesTarget,
             "hit_class": $0.hitClassName ?? "", "accepts": $0.acceptsFirstMouse, "enabled": $0.isEnabled,
             "first_click": $0.actsOnFirstClick]
        }
        return ["app_active": NSApp.isActive, "key": report.keyHolder.rawValue, "key_class": report.keyClassName ?? "",
                "policy": report.policyTakesPress, "targets": targets]
    }

    private func target(_ view: NSView, visible: NSRect, frameView: NSView, window: NSWindow, policy: Bool) -> Target {
        let center = view.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
        let hit = frameView.hitTest(center)
        let press = NSEvent.mouseEvent(with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        let accepts = (hit ?? view).acceptsFirstMouse(for: press)
        let height = window.contentView?.bounds.height ?? window.frame.height
        return Target(className: String(describing: type(of: view)),
                      label: view.accessibilityLabel() ?? (view as? NSButton)?.title ?? "",
                      center: CGPoint(x: center.x, y: height - center.y),
                      reachesTarget: hit.map { $0 === view || $0.isDescendant(of: view) } ?? false,
                      hitClassName: hit.map { String(describing: type(of: $0)) },
                      acceptsFirstMouse: accepts, isEnabled: (view as? NSControl)?.isEnabled ?? true,
                      actsOnFirstClick: policy || accepts)
    }

    private func holder(_ key: NSWindow?, for window: NSWindow) -> KeyHolder {
        guard let key else { return .none }
        if key === window { return .window }
        var parent = key.parent
        while let current = parent {
            if current === window { return .page }
            parent = current.parent
        }
        return key is NSPanel ? .panel : .other
    }
}

@MainActor private func visit(_ view: NSView, _ body: (NSView) -> Void) {
    body(view)
    for sub in view.subviews { visit(sub, body) }
}

@MainActor private func isTarget(_ view: NSView, baseMouseDown: IMP?) -> Bool {
    if let field = view as? NSTextField { return field.isEditable }
    if view is NSControl { return true }
    if String(describing: type(of: view)).hasPrefix("NSHostingView") { return true }
    return type(of: view).instanceMethod(for: #selector(NSView.mouseDown(with:))) != baseMouseDown
}
#endif
