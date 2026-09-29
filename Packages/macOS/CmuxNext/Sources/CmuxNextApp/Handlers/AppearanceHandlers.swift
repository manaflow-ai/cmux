import CmuxNextActions
import CoreGraphics
import CmuxNextDesign
import CmuxNextSettings
import os

/// Density and interface size (the chrome body font; terminal fonts come
/// from the Ghostty config). Applied to `DesignSettings` at once, then
/// written to cmux.json, which owns settings; the watcher reapplies the
/// same value.
enum AppearanceHandlers {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("appearance.density.compact", run: { _ in setDensity(.compact, context) })
        registry.bind("appearance.density.comfortable", run: { _ in setDensity(.comfortable, context) })
        registry.bind("appearance.interfaceSize.increase", run: { _ in stepInterfaceSize(by: 1, context) })
        registry.bind("appearance.interfaceSize.decrease", run: { _ in stepInterfaceSize(by: -1, context) })
        registry.bind("appearance.interfaceSize.reset", run: { _ in
            DesignSettings.shared.setOverride(.chromeFontSize, nil)
            write(context, "reset interface size") { try await $0.file.remove(fontSizePath) }
        })
    }

    private static let fontSizePath = ["appearance", "metrics", MetricKey.chromeFontSize.rawValue]

    private static func setDensity(_ density: Density, _ context: AppActionContext) {
        DesignSettings.shared.density = density
        write(context, "set density") { try await $0.setDensity(density) }
    }

    /// Body size in points: the override, else the density default.
    static func interfaceSize(_ design: DesignSettings = .shared) -> Double {
        Double(design.overrides[.chromeFontSize] ?? (design.density == .compact ? 12 : 13))
    }

    private static func stepInterfaceSize(by delta: Double, _ context: AppActionContext) {
        let design = DesignSettings.shared
        design.setOverride(.chromeFontSize, CGFloat(interfaceSize(design) + delta))
        let size = interfaceSize(design)
        write(context, "set interface size") { try await $0.set(.number(size), at: fontSizePath) }
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
