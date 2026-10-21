import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings

/// The one path every density entry point takes (palette rows, Set Density, `cmux density`,
/// MCP and the Settings card): it resolves a density id, applies it to `DesignSettings` at once
/// and saves it to cmux.json (plans/cmux-next/density-DESIGN.md). Choosing the density already in
/// use says so (`notify`), so Enter is never silent.
@MainActor
final class DensityController {
    private let context: AppActionContext
    private let notify: @MainActor (String) -> Void

    /// - Parameters:
    ///   - context: The action context whose `design` and settings writes the controller uses.
    ///   - notify: Shows a short message (a toast on the active window by default; tests record it).
    init(context: AppActionContext, notify: (@MainActor (String) -> Void)? = nil) {
        self.context = context
        self.notify = notify ?? { message in DensityController.toast(message, context: context) }
    }

    private var design: DesignSettings { context.design }

    /// Applies the density `id` (a built-in or a custom density) and saves it.
    /// - Throws: `ActionFailure.invalidTarget` when no density has `id`, or the key is managed.
    func apply(id: String) throws {
        guard let density = design.density(id: id) else {
            throw ActionFailure.invalidTarget(DensityStrings.unknown(id))
        }
        let name = DensityNames().name(density)
        guard density != design.densityTokens else {
            notify(DensityStrings.alreadyUsing(name))
            return
        }
        let densityPath = DensitySetting().configPath, customPath = CustomDensitySelectionSetting().configPath
        try AppearanceHandlers.requireUnmanaged(densityPath, context)
        try AppearanceHandlers.requireUnmanaged(customPath, context)
        design.densityTokens = density
        if density.isBuiltIn {
            context.writeSettings("set density", [(densityPath, .string(density.id)), (customPath, nil)], reloadOnFailure: true)
        } else {
            context.writeSettings("set custom density", [(customPath, .string(density.id))], reloadOnFailure: true)
        }
    }

    /// Makes a custom density from `basedOn` (default: the density in use) named `name`, with
    /// `fontSize` when given, saves it and switches to it.
    /// - Returns: The new density.
    @discardableResult
    func create(name: String, basedOn: String?, fontSize: Double?) throws -> DensityTokens {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ActionFailure.invalidTarget(DensityStrings.nameRequired) }
        let base: DensityTokens
        if let basedOn, !basedOn.isEmpty {
            guard let found = design.density(id: basedOn) else { throw ActionFailure.invalidTarget(DensityStrings.unknown(basedOn)) }
            base = found
        } else {
            base = design.densityTokens
        }
        var made = CustomDensitiesSetting.duplicate(base, name: trimmed, existing: design.customDensities)
        if let fontSize { made = DensityTokens(id: made.id, name: made.name, basedOn: made.basedOn, level: made.level,
                                                spacing: made.spacing, fontSize: fontSize, tokens: made.tokens) }
        let listPath = CustomDensitiesSetting().configPath, customPath = CustomDensitySelectionSetting().configPath
        try AppearanceHandlers.requireUnmanaged(listPath, context)
        try AppearanceHandlers.requireUnmanaged(customPath, context)
        let list = design.customDensities + [made]
        design.customDensities = list
        design.densityTokens = made
        context.writeSettings("create density", [(listPath, .array(list.map(CustomDensitiesSetting.json))), (customPath, .string(made.id))],
                              reloadOnFailure: true)
        notify(DensityStrings.created(made.name))
        return made
    }

    /// Every density as an argument value: built-ins (localized names), then custom ones.
    func choices() -> [ActionEnumCase] {
        design.availableDensities.map { ActionEnumCase(value: $0.id, title: DensityNames().name($0)) }
    }

    private static func toast(_ message: String, context: AppActionContext) {
        guard let window = context.services.windows.active?.window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        _ = CmuxToastCenter.shared.show(CmuxToast(id: "density", message: message, duration: .seconds(3)), in: window)
    }
}
