import AppKit
import CmuxNextInput

/// An Escape key-down intercept on the strip's window, held only while the strip is in one mode (a
/// drag in flight, a multi-selection): the strip calls ``install()`` when the mode begins and
/// ``remove()`` when it ends or the strip leaves sight. Outside its mode the strip costs the input
/// tap nothing.
///
/// Chrome holds its drag's Escape handler the same way: `TabDragController` makes its
/// `KeyEventTracker` when the drag starts and drops it when the drag ends
/// (chrome/browser/ui/views/tabs/tab_drag_controller.cc).
@MainActor final class TabStripEscape {
    /// The virtual key code of Escape (`kVK_Escape`).
    static let escapeKeyCode: UInt16 = 53

    private weak var strip: TabStripView?
    private let order: InputEventTap.InterceptOrder
    private let action: (TabStripView) -> InputEventTap.InterceptResult
    private var subscription: InputSubscription?
    /// The window the subscription hears; an install in another window subscribes again.
    private weak var window: NSWindow?

    /// - Parameters:
    ///   - order: Where the intercept runs among the tap's others.
    ///   - action: Runs for each Escape key-down in the strip's window while installed; `.consume`
    ///     keeps the key from the responder chain.
    private init(strip: TabStripView, order: InputEventTap.InterceptOrder,
                 action: @escaping (TabStripView) -> InputEventTap.InterceptResult) {
        self.strip = strip
        self.order = order
        self.action = action
    }

    /// Escape cancels the tab or group drag in flight and stops there (`cancelDrag`). The strip holds
    /// it from the drag's start until the drag ends or is handed off.
    static func dragCancel(strip: TabStripView) -> TabStripEscape {
        TabStripEscape(strip: strip, order: .dragSession) { strip in
            guard strip.drag != nil || strip.groups.drag != nil else { return .pass }
            strip.cancelDrag()
            return .consume
        }
    }

    /// Escape ends a multi-selection (Chrome) and goes on to whatever has focus (a terminal still gets
    /// it). The strip holds it while it has a multi-selection.
    static func multiSelectionClear(strip: TabStripView) -> TabStripEscape {
        TabStripEscape(strip: strip, order: .standard) { strip in
            guard strip.isShownInWindow, strip.drag == nil else { return .pass }
            strip.model.clearMultiSelection()
            return .pass
        }
    }

    /// Whether the intercept is held now.
    var isInstalled: Bool { subscription != nil }

    /// Starts hearing Escape in the strip's window (nothing while the strip has no window).
    func install() {
        guard let strip, let window = strip.window else { return remove() }
        guard subscription == nil || self.window !== window else { return }
        subscription?.cancel()
        self.window = window
        let action = action
        subscription = strip.inputTap.subscribe(class: .key, phase: .intercept(order: order), window: .window(window)) { [weak strip] event in
            guard event.type == .keyDown, event.keyCode == Self.escapeKeyCode, let strip else { return .pass }
            return action(strip)
        }
    }

    func remove() {
        subscription?.cancel()
        subscription = nil
        window = nil
    }
}
