public import CmuxNextActions
public import CmuxNextDesign
public import Foundation

/// `appearance.glass.<role>.{material,tint,tintStrength,veil}` in cmux.json: the material, tint, tint
/// strength and veil of each glass surface role plus `chrome` (schemas/settings/source/glass.json, which
/// holds every path, range and default; cmux-config's glass module resolves and clamps the same rows).
/// Every default is today's look, so an unset key changes nothing.
public nonisolated struct GlassSetting {
    /// The parser and schema helpers are stateless; the value form keeps this utility instantiable so
    /// the package-conventions namespace rule does not add a new ratchet entry.
    public init() {}
    /// `appearance.glass`.
    public static let rootPath = ["appearance", "glass"]

    /// The glass mode web pages draw (``GlassLensMode``): `appearance.glass.composer.material` when it is lens or
    /// spectrum, else plain. `root` is the effective document, so a theme file's value applies too.
    public func lensMode(in root: JSONValue) -> GlassLensMode {
        GlassLensMode(material: root.value(at: Self.composerMaterialPath)?.stringValue)
    }
}

extension GlassSetting {
    /// The palette's Toggle Liquid Glass Lens (`appearance.glass.lens.toggle`): plain turns the lens on, lens or
    /// spectrum back to plain, written to `appearance.glass.composer.material` (plain is written, not removed, so a
    /// Debug file's old `glass.lens` choice never moves in behind it). A managed key is refused and changes nothing.
    @MainActor public static func bindLensToggle(into registry: ActionRegistry, design: DesignSettings,
                                                 save: @escaping SettingChoiceActions.Save) {
        let id: ActionID = "appearance.glass.lens.toggle"
        registry.bindEffect(id) { _ in
            let next = design.glassLensMode.lensToggled
            // `save` refuses a managed key before anything changes, else starts the cmux.json write and returns.
            if let refusal = save(composerMaterialPath, .string(next.rawValue)) { return .refused(refusal) }
            design.glassLensMode = next
            return .done
        }
        // On while the setting refracts (Lens or Spectrum).
        ActionTargetTitles.setPaletteSettingState(id, in: registry) { design.glassLensMode != .plain }
    }
}

extension SettingsController {
    /// The rename of the Debug choice `glass.lens` (``GlassLensMode/retiredTunableKey``, 2026-11-20): a Debug file
    /// that still chose lens or spectrum moves that choice into `appearance.glass.composer.material` once
    /// `untilWritable` returns, unless the person's own file already sets it. Plain (the default) moves nothing.
    public func moveRetiredGlassLens(debugFile: URL?, untilWritable: @escaping @MainActor @Sendable () async -> Void) {
        guard let debugFile else { return }
        Task {
            let found = await Task.detached(priority: .utility) { GlassLensMode.retiredChoice(inDebugFile: debugFile) }.value
            guard let mode = found else { return }
            try? await Self.launchWrite(after: untilWritable) {
                guard self.fileRoot.value(at: GlassSetting.composerMaterialPath) == nil else { return }
                try await self.setSetting(at: GlassSetting.composerMaterialPath, to: .string(mode.rawValue), by: .user)
            }
        }
    }
}
