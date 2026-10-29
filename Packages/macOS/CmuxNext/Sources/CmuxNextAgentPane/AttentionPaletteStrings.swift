import Foundation

/// Text of the Go to What Needs Me page. Keys live in Resources/MiscHandlers.xcstrings.
public struct AttentionPaletteStrings {
    public static var title: String { String(localized: "handlers.attention.title", defaultValue: "What Needs You", table: "MiscHandlers", bundle: .module) }
    public static var placeholder: String { String(localized: "handlers.attention.placeholder", defaultValue: "Search what needs you", table: "MiscHandlers", bundle: .module) }
    public static var open: String { String(localized: "handlers.attention.open", defaultValue: "Go to Tab", table: "MiscHandlers", bundle: .module) }
    public static var needsFocus: String {
        String(localized: "handlers.attention.needsFocus",
               defaultValue: "Go to What Needs Me opens only when focus is requested; read the marked tabs with tab.list",
               table: "MiscHandlers", bundle: .module)
    }
    public static var nothing: String { String(localized: "handlers.attention.nothing", defaultValue: "No agent needs you in a tab right now.", table: "MiscHandlers", bundle: .module) }
}
