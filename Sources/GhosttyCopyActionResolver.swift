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
            "copy_to_clipboard:\(rawValue)"
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
        // The implementation is completed in the fix commit. Keeping the
        // default here makes the regression test fail against this commit.
        Self.defaultAction
    }
}
