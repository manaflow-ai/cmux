public import AppKit

/// The action a standard macOS titlebar runs on a double-click: zoom by
/// default, or minimize when the user's `AppleActionOnDoubleClick` /
/// `AppleMiniaturizeOnDoubleClick` preference selects it.
public enum StandardTitlebarDoubleClickAction: Equatable {
    case miniaturize
    case zoom
    case none

    /// Resolves the action macOS would take from a copy of the global defaults
    /// domain (`AppleActionOnDoubleClick` / `AppleMiniaturizeOnDoubleClick`),
    /// defaulting to ``zoom``.
    public static func resolved(globalDefaults: [String: Any]) -> StandardTitlebarDoubleClickAction {
        if let action = (globalDefaults["AppleActionOnDoubleClick"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            switch action {
            case "minimize", "miniaturize":
                return .miniaturize
            case "maximize", "zoom", "fill":
                return .zoom
            case "none", "no action":
                return .none
            default:
                break
            }
        }

        if let miniaturizeOnDoubleClick = globalDefaults["AppleMiniaturizeOnDoubleClick"] as? Bool,
           miniaturizeOnDoubleClick {
            return .miniaturize
        }

        return .zoom
    }

    /// Runs the same action macOS titlebars use for double-click on `window`,
    /// reading the live global defaults domain: zoom by default, or minimize
    /// when the user preference is set. Returns the action performed, or `nil`
    /// when `window` is `nil`.
    @MainActor
    @discardableResult
    public static func performStandard(window: NSWindow?) -> StandardTitlebarDoubleClickAction? {
        guard let window else { return nil }

        let globalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        let action = resolved(globalDefaults: globalDefaults)
        switch action {
        case .miniaturize:
            window.miniaturize(nil)
        case .zoom:
            window.zoom(nil)
        case .none:
            break
        }
        return action
    }
}
