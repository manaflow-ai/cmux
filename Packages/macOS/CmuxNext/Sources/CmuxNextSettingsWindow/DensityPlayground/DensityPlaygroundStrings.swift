import CmuxNextDesign
import Foundation

/// Chrome text of the Density Playground (Localizable.xcstrings in this module). Value labels and help are English
/// developer text declared with ``DensityTokenCatalog``, as tunable labels are.
public nonisolated struct DensityPlaygroundStrings {
    public nonisolated init() {}
    /// The window's title and its palette row.
    public static var title: String { text("densityPlayground.title", "Density Playground") }
    static var density: String { text("densityPlayground.density", "Density") }
    static var name: String { text("densityPlayground.name", "Name") }
    static var duplicate: String { text("densityPlayground.duplicate", "Duplicate") }
    static var delete: String { text("densityPlayground.delete", "Delete") }
    static func confirmDelete(_ name: String) -> String { format("densityPlayground.confirmDelete", "Delete “%@”", name) }
    static var copyJSON: String { text("densityPlayground.copyJSON", "Copy JSON") }
    static var copySwift: String { text("densityPlayground.copySwift", "Copy as Swift") }
    static var pasteJSON: String { text("densityPlayground.pasteJSON", "Paste JSON") }
    static var copied: String { text("densityPlayground.copied", "Copied") }
    static var changedOnly: String { text("densityPlayground.changedOnly", "Changed only") }
    static var saving: String { text("densityPlayground.saving", "Saving…") }
    static var saved: String { text("densityPlayground.saved", "Saved") }
    static var builtInHint: String {
        text("densityPlayground.builtInHint", "Built-in densities stay as they are. Your first change makes a copy.")
    }
    /// The status line while a policy manages the density keys.
    public static var managedNotice: String {
        text("densityPlayground.managedNotice", "Your organization manages density. Changes show now but are not saved.")
    }
    /// The status line while the active theme file carries its own density.
    public static var themeFileNotice: String {
        text("densityPlayground.themeFileNotice", "Your theme file sets this density. Changes show now but are not saved.")
    }
    /// The save state while a policy manages the density keys.
    static var notSaved: String { text("densityPlayground.notSaved", "Not saved") }
    static var importFailed: String { text("densityPlayground.importFailed", "The clipboard holds no density JSON.") }
    /// The name of a copy of `name`.
    static func copyName(_ name: String) -> String { format("densityPlayground.copyName", "%@ Custom", name) }
    static func changedCount(_ count: Int, base: String) -> String {
        String(format: text("densityPlayground.changedCount", "%lld changed from %@"), locale: Locale.current, count, base)
    }
    static func group(_ group: DensityTokenCatalog.Group) -> String {
        switch group {
        case .verticalTabs: text("densityPlayground.group.verticalTabs", "Vertical tabs")
        case .horizontalTabs: text("densityPlayground.group.horizontalTabs", "Horizontal tabs")
        case .other: text("densityPlayground.group.other", "Other")
        }
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ argument: String) -> String {
        String(format: text(key, value), argument)
    }
}
