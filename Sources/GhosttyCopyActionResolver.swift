import AppKit

/// Resolves the Ghostty action used by native terminal Copy commands.
struct GhosttyCopyActionResolver {
    /// The formats accepted by Ghostty's `copy_to_clipboard` action.
    enum Flavor: String, CaseIterable {
        case plain
        case vt
        case html
        case mixed

        var bindingAction: String {
            switch self {
            case .mixed:
                // Keep the parameterless spelling as the default action so
                // native Copy retains Ghostty's version-defined mixed default.
                "copy_to_clipboard"
            case .plain, .vt, .html:
                "copy_to_clipboard:\(rawValue)"
            }
        }
    }

    /// A copy flavor and the trigger Ghostty associates with that action.
    struct Binding: Equatable {
        let flavor: Flavor
        let shortcut: StoredShortcut

        init(flavor: Flavor, shortcut: StoredShortcut) {
            self.flavor = flavor
            self.shortcut = shortcut
        }
    }

    /// The action string Ghostty uses when no flavor-specific override is found.
    static let defaultAction = "copy_to_clipboard"

    /// The standard macOS Copy trigger.
    static let standardCopyShortcut = StoredShortcut(
        key: "c",
        command: true,
        shift: false,
        option: false,
        control: false
    )

    /// Returns the configured copy action for the native Copy surfaces.
    func resolve(bindings: [Binding]) -> String {
        // Ghostty's reverse trigger lookup omits `performable` bindings. The
        // standard Cmd+C binding is therefore only present here when the user
        // explicitly overrides it with a non-performable `copy_to_clipboard`
        // action (the form that AppKit routes through the native menu). If a
        // malformed config exposes multiple flavors for the same trigger, use
        // the safe mixed default instead of inventing an ordering Ghostty did
        // not expose through its reverse map.
        let matchingBindings = bindings.filter {
            $0.shortcut == Self.standardCopyShortcut
        }
        guard matchingBindings.count == 1,
              let binding = matchingBindings.first else {
            return Self.defaultAction
        }
        return binding.flavor.bindingAction
    }
}

extension GhosttyApp {
    /// The copy action native menu surfaces should send to Ghostty.
    var configuredCopyToClipboardAction: String {
        let bindings = GhosttyCopyActionResolver.Flavor.allCases.compactMap { flavor in
            storedShortcut(forBindingAction: flavor.bindingAction).map {
                GhosttyCopyActionResolver.Binding(flavor: flavor, shortcut: $0)
            }
        }
        return GhosttyCopyActionResolver().resolve(bindings: bindings)
    }
}
