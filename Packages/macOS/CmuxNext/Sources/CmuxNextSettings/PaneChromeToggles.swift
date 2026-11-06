public import CmuxNextActions
public import CmuxNextDesign
import CoreGraphics

/// The palette's on/off pane chrome actions: Toggle Pane Borders (`layout.paneBorder`), Toggle Pane
/// Padding (`layout.panePadding`), Toggle Rounded Pane Corners (`layout.paneCornerRadius`) and Toggle
/// Thick Pane Borders (`layout.paneBorderWidth`).
///
/// Each action applies its change to ``DesignSettings`` at once after `save` accepted the cmux.json
/// write (a managed key refuses and changes nothing; the default removes the key). Each palette row
/// says whether its setting is on now, read the way the action decides which way to flip.
///
/// ```swift
/// PaneChromeToggles(design: DesignSettings(), save: { _, _ in nil }).bind(into: registry)
/// ```
@MainActor public struct PaneChromeToggles {
    private let design: DesignSettings
    private let save: SettingChoiceActions.Save

    /// - Parameters:
    ///   - design: Where the live value is applied and read; the app passes its shared one.
    ///     Padding and corner radius are read through `Metrics`, which reads the shared one.
    ///   - save: Writes one key to cmux.json, or returns why it may not (the key is managed).
    public init(design: DesignSettings, save: @escaping SettingChoiceActions.Save) {
        self.design = design
        self.save = save
    }

    /// Binds the four actions and their palette states into `registry`.
    public func bind(into registry: ActionRegistry) {
        let design = design
        bindToggle("appearance.paneBorder.toggle", path: "paneBorder", into: registry, isOn: { (design.paneChrome.border ?? .subtle) == .subtle }) {
            // The configured border, not the drawn one (appearance.borders none draws none). Subtle is the default.
            var chrome = design.paneChrome
            chrome.border = $0 ? nil : PaneBorderStyle.none
            return (chrome, chrome.border.map { JSONValue.string($0.rawValue) })
        }
        bindToggle("appearance.panePadding.toggle", path: "panePadding", into: registry, isOn: { Metrics.panePadding > 0 }) {
            // Off is 0; on is the density default, written explicitly where that default is edge to edge.
            var chrome = design.paneChrome
            chrome.padding = $0 ? Self.unsetOrExplicit(\.padding, in: chrome, design: design, metric: { Metrics.panePadding }, explicit: Metrics.densityPanePadding) : 0
            return (chrome, chrome.padding.map { JSONValue.number(Double($0)) })
        }
        bindToggle("appearance.paneCorners.toggle", path: "paneCornerRadius", into: registry, isOn: { Metrics.cornerRadius > 0 }) {
            // Off is square (0) for panes, the main pane and tabs alike (one radius); on is the default radius.
            var chrome = design.paneChrome
            chrome.cornerRadius = $0 ? Self.unsetOrExplicit(\.cornerRadius, in: chrome, design: design, metric: { Metrics.cornerRadius },
                                                            explicit: Metrics.densityPaneCornerRadius) : 0
            return (chrome, chrome.cornerRadius.map { JSONValue.number(Double($0)) })
        }
        bindToggle("appearance.paneBorderWidth.toggle", path: "paneBorderWidth", into: registry, isOn: { design.paneChrome.borderWidth != nil }) {
            // One device pixel (the default, key removed) or 2 pt.
            var chrome = design.paneChrome
            chrome.borderWidth = $0 ? 2 : nil
            return (chrome, chrome.borderWidth.map { JSONValue.number(Double($0)) })
        }
    }

    /// Binds one `layout.<path>` toggle: `change(on)` returns the chrome to apply and the file value.
    private func bindToggle(_ id: ActionID, path key: String, into registry: ActionRegistry, isOn: @escaping @MainActor () -> Bool,
                            change: @escaping @MainActor (Bool) -> (PaneChromeOverrides, JSONValue?)) {
        let (design, save) = (design, save)
        registry.bindEffect(id) { _ in
            let before = design.paneChrome
            let (chrome, value) = change(!isOn())
            if let refusal = save(["layout", key], value) {
                design.setPaneChrome(before)
                return .refused(refusal)
            }
            design.setPaneChrome(chrome)
            return .done
        }
        ActionTargetTitles.setPaletteState(id, in: registry, isOn)
    }

    /// Nil (the default) when the default shows `metric` above 0, else `explicit`. The probe applies
    /// the unset chrome to `design`; the caller applies the result (or the chrome before, on a refusal).
    private static func unsetOrExplicit(_ field: WritableKeyPath<PaneChromeOverrides, CGFloat?>, in chrome: PaneChromeOverrides,
                                        design: DesignSettings, metric: () -> CGFloat, explicit: CGFloat) -> CGFloat? {
        var unset = chrome
        unset[keyPath: field] = nil
        design.setPaneChrome(unset)
        return metric() > 0 ? nil : explicit
    }
}
