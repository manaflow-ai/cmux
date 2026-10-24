import CmuxNextCompat
import Foundation

/// Needs you's mode on every open agent page, followed live (Leo 2026-10-22: "the needs you thingy
/// doesnt even work yet ofc"): off while the App Store item `agentPane.needsYou.enabled` is not
/// installed (``installed``, set by the App), else the Debug choice `agentPane.debug.needsYou`
/// (``AgentPaneTunables/needsYouStyle(installed:debug:)`` decides). A new page starts with it in its
/// `data-needs-you` (``AgentPaneTunables/documentAttributes``); each page gets it again at load and
/// handshake (``push(to:)``, ``event(for:)``) and on every change, so installing the item shows the
/// inbox in every open chat, and in the page AgentTabs prewarms at launch, without a reload. Not an
/// AgentPaneView extension: that type is at its size limit.
public final class AgentPaneNeedsYou {
    public static let shared = AgentPaneNeedsYou()
    /// The pages pushed so far, held weakly, for the pushes on a change.
    private let views = NSHashTable<AgentPaneView>.weakObjects()
    private var observation: Task<Void, Never>?
    /// Whether the App Store item is installed, read through Observation (the App reads its
    /// settings snapshot); a host with no settings reads off.
    public var installed: @MainActor () -> Bool = { false } {
        // A new source: follow it, which pushes its value to every page pushed so far.
        didSet { observation?.cancel(); observation = nil; follow() }
    }

    /// The mode the pages show now.
    var style: AgentPaneNeedsYouStyle {
        AgentPaneTunables.needsYouStyle(installed: installed(), debug: AgentPaneTunables.needsYou.value)
    }

    /// The script that tells a loaded page on the old host the mode.
    static func script(_ style: AgentPaneNeedsYouStyle) -> String {
        "window.cmuxAcpmuxBridge?.applyNeedsYou?.(\"\(style.rawValue)\");"
    }

    /// The mode, read now, as a page host event; `view` then also gets every change.
    func event(for view: AgentPaneView) -> AgentPageEvent {
        views.add(view)
        follow()
        return .needsYou(style)
    }

    /// Pushes the mode, read now, to `view`'s page; `view` then also gets every change.
    func push(to view: AgentPaneView) {
        views.add(view)
        follow()
        send(style, to: view)
    }

    private func send(_ style: AgentPaneNeedsYouStyle, to view: AgentPaneView) {
        view.deliver([.needsYou(style)], scripts: [Self.script(style)])
    }

    // Same shape as AgentPaneView's (cx-t7hu): not an isolated deinit.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { observation?.cancel() }
    }

    private func follow() {
        guard observation == nil else { return }
        // task-owner: app-lifetime; event-driven (Observation on the setting and the tunable key)
        observation = Task { [weak self] in
            for await style in ObservationStream({ [weak self] in self?.style ?? .off }) {
                guard let self else { return }
                for view in views.allObjects { send(style, to: view) }
            }
        }
    }
}
