import AppKit
public import CmuxNextActions
public import CmuxNextDaemon
public import CoreGraphics

/// Floating panes (`floating-panes-v1`): the commands that float a pane, put it back and give it a frame. A daemon
/// without the capability gets no command. ``NewFloatingPane`` opens a new pane that floats.
extension DaemonService {
    /// Whether this daemon has floating panes.
    public var floatsPanes: Bool { supports(DaemonCapability.floatingPanes.rawValue) }

    /// Floats `pane` above the tiled panes of its screen, or puts a floating pane back into its place.
    public func toggleFloating(_ pane: PaneID) {
        guard floatsPanes else { return }
        Task { await run("float-pane") { _ = try await $0.floatPane(pane) } }
    }

    /// Gives the floating pane `pane` the frame `frame` (fractions of its screen's pane area) and brings it to the
    /// front. The layout shows the frame already; the daemon's next layout confirms it or puts its own back.
    public func setFloatingFrame(of pane: PaneID, to frame: CGRect) {
        guard floatsPanes else { return }
        let wire = FloatingPaneSnapshot.Frame(x: Double(frame.minX), y: Double(frame.minY), w: Double(frame.width), h: Double(frame.height))
        Task { await run("float-pane") { _ = try await $0.floatPane(pane, mode: .on, frame: wire) } }
    }

    /// Toggles the workspace's durable Quick Terminal on the screen shown by the app.
    public func toggleQuickTerminal(on screen: ScreenID) {
        guard supports(DaemonCapability.quickTerminal.rawValue) else { return }
        Task { await request("quick-terminal") { try await $0.request(QuickTerminalRequest(screen: screen)) } }
    }
}

/// The actions of floating panes: Float Pane, New Floating Pane, the debug action that opens the look's knobs, and
/// the rule that a floating pane has no zoom. Their titles and keys live here until the action catalog has them.
public enum FloatingPaneActions {
    /// The debug action that opens the knobs of the look (the palette's "Debug: Floating Pane Look").
    public static let lookAction: ActionID = "debug.floatingPaneLook"
    /// The Debug Settings section of those knobs (`FloatingPaneTunables.section`).
    public static let lookSection = "floatingPane"

    /// Registers the actions.
    ///
    /// - Parameters:
    ///   - registry: The registry the actions go into; Toggle Pane Zoom is bound in it already.
    ///   - openLook: Opens Debug Settings on the section it gets; the flag says if the window can take the focus.
    ///   - target: The daemon and the pane an invocation is for (the focused pane, or the pane it names), and the
    ///     focus of the window that shows that pane (nil when no window shows it).
    public static func register(into registry: ActionRegistry, openLook: @escaping @MainActor (String, Bool) throws -> Void,
                                target: @escaping @MainActor (ActionInvocation) -> (DaemonService, PaneID, NewPaneFocus?)?) {
        registry.register(Action(
            id: "toggleFloatingPane", title: FloatingPaneStrings.float, keywords: ["floating", "float", "tile", "overlay"],
            shortcut: Shortcut("\r", modifiers: [.option, .shift, .command]),
            invoke: { invocation in
                guard let (daemon, pane, _) = target(invocation) else { return }
                daemon.toggleFloating(pane)
            },
            handler: {}
        ))
        var quickTerminal = Action(
            id: "toggleQuickTerminal", title: "Toggle Quick Terminal", keywords: ["quick", "terminal", "floating", "scratch"],
            invoke: { invocation in
                guard let (daemon, pane, _) = target(invocation),
                      let screen = daemon.store.screen(containing: pane)?.handle else { return }
                daemon.toggleQuickTerminal(on: screen)
            },
            handler: {}
        )
        quickTerminal.targetUnavailableReason = { invocation in
            guard let (daemon, pane, _) = target(invocation) else { return "No pane is available for Quick Terminal." }
            return daemon.supports(DaemonCapability.quickTerminal.rawValue) ? nil : "This daemon does not support Quick Terminal."
        }
        registry.register(quickTerminal)
        registry.register(Action(
            id: "newFloatingPane", title: FloatingPaneStrings.new, keywords: ["floating", "float", "overlay", "scratch"],
            shortcut: Shortcut("n", modifiers: [.control, .shift, .command]),
            invoke: { [weak registry] invocation in
                guard let (daemon, pane, window) = target(invocation) else { return }
                // A key run shows the act's failure as a notice; a caller that waits (`action.run`) gets it.
                let work = NewFloatingPane.start(on: daemon, beside: pane, window: window)
                registry?.trackOrRefuse(work)
            },
            handler: {}
        ))
        withholdZoom(in: registry) { [weak registry] invocation in
            // A read behind a rule: a target that is gone refuses nothing here.
            guard let registry, let (daemon, pane, _) = registry.withoutRefusals({ target(invocation) }) else { return false }
            return daemon.store.screen(containing: pane)?.floating.contains { $0.pane == pane } ?? false
        }
        // DEV and NIGHTLY, with Internal Developer Mode on (`DebugActionGate`): a palette row only.
        registry.seed([ActionDescriptor(
            id: lookAction, title: String(format: DebugActionGate.titleFormat, FloatingPaneStrings.look),
            keywords: ["floating", "float", "opacity", "transparency", "background", "material", "blur", "tint", "border", "shadow", "corner"],
            category: .pane, isDebugOnly: true
        )])
        registry.bindEffect(lookAction, effect: { invocation in
            do {
                try openLook(lookSection, invocation.allowsViewChange)
            } catch {
                return .refused((error as? ActionFailure)?.message ?? String(describing: error))
            }
            return .done
        })
    }

    /// A floating pane has no zoom: this is the ONE place of that rule. The key does nothing there and shows no
    /// notice; the palette does not offer the row while the focused pane floats; a floating pane's context menu
    /// and its toolbar leave the action out; a run that names a floating pane is refused with the reason.
    ///
    /// - Parameters:
    ///   - registry: The registry that has Toggle Pane Zoom bound.
    ///   - floats: Whether the pane of an invocation floats now (the focused pane when it names none).
    static func withholdZoom(in registry: ActionRegistry, floats: @escaping @MainActor (ActionInvocation) -> Bool) {
        guard var zoom = registry.action(for: "toggleSplitZoom"), let effect = zoom.effect else { return }
        let hidden = zoom.targetHidden, reason = zoom.targetUnavailableReason
        zoom.effect = { floats($0) ? .done : effect($0) }
        zoom.paletteHidden = { floats(ActionInvocation()) }
        zoom.targetHidden = { floats($0) || hidden?($0) == true }
        zoom.targetUnavailableReason = { $0.target != nil && floats($0) ? FloatingPaneStrings.noZoom : reason?($0) }
        registry.register(zoom)
    }
}
