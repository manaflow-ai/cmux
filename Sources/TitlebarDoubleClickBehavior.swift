import AppKit
import Bonsplit
import SwiftUI


// MARK: - Titlebar double-click behavior and standard actions
/// Runs the same action macOS titlebars use for double-click:
/// zoom by default, or minimize when the user preference is set.
enum StandardTitlebarDoubleClickAction: Equatable {
    case miniaturize
    case zoom
    case none
}

enum TitlebarDoubleClickBehavior: Equatable {
    case standardAction
    case suppress
}

enum TitlebarDoubleClickHandlingResult: Equatable {
    case ignored
    case suppressed
    case performed(StandardTitlebarDoubleClickAction)

    var consumesEvent: Bool {
        self != .ignored
    }
}

func resolvedStandardTitlebarDoubleClickAction(globalDefaults: [String: Any]) -> StandardTitlebarDoubleClickAction {
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

/// Runs the same action macOS titlebars use for double-click:
/// zoom by default, or minimize when the user preference is set.
@MainActor
@discardableResult
func performStandardTitlebarDoubleClick(window: NSWindow?) -> StandardTitlebarDoubleClickAction? {
    guard let window else { return nil }

    let globalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
    let action = resolvedStandardTitlebarDoubleClickAction(globalDefaults: globalDefaults)
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

@discardableResult
@MainActor
func handleTitlebarDoubleClick(
    window: NSWindow?,
    behavior: TitlebarDoubleClickBehavior
) -> TitlebarDoubleClickHandlingResult {
    switch behavior {
    case .standardAction:
        guard let action = performStandardTitlebarDoubleClick(window: window) else {
            return .ignored
        }
        return .performed(action)
    case .suppress:
        return .suppressed
    }
}

