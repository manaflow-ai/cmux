import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import os

/// `focusRing.*` palette actions: applied to `DesignSettings` at once, then
/// written to cmux.json, which owns settings; the watcher reapplies them.
enum FocusRingHandlers {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("focusRing.toggle", run: { _ in
            update(context, key: "enabled") { ring in
                ring.enabled.toggle()
                return .bool(ring.enabled)
            }
        })
        registry.bind("focusRing.style.ring", run: { _ in setStyle(.ring, context) })
        registry.bind("focusRing.style.glow", run: { _ in setStyle(.glow, context) })
        registry.bind("focusRing.singlePane.toggle", run: { _ in
            update(context, key: "showWhenSinglePane") { ring in
                ring.showsForSinglePane.toggle()
                return .bool(ring.showsForSinglePane)
            }
        })
    }

    /// Choosing a style also turns the ring on.
    private static func setStyle(_ style: FocusRingStyle, _ context: AppActionContext) {
        let design = DesignSettings.shared
        var ring = design.focusRing
        let wasEnabled = ring.enabled
        ring.style = style
        ring.enabled = true
        design.focusRing = ring
        write(context, "set focus ring style") { settings in
            try await settings.set(.string(style.rawValue), at: ["focusRing", "style"])
            if !wasEnabled { try await settings.set(.bool(true), at: ["focusRing", "enabled"]) }
        }
    }

    private static func update(_ context: AppActionContext, key: String, _ change: (inout FocusRingSettings) -> JSONValue) {
        let design = DesignSettings.shared
        var ring = design.focusRing
        let value = change(&ring)
        design.focusRing = ring
        write(context, "set focusRing.\(key)") { try await $0.set(value, at: ["focusRing", key]) }
    }

    private static func write(_ context: AppActionContext, _ label: String,
                              _ body: @escaping @Sendable (SettingsController) async throws -> Void) {
        guard let settings = context.services.settings else { return }
        Task {
            do { try await body(settings) } catch {
                logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
