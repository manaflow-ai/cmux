import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation

extension PageDescriptor {
    /// The one icon picker (R94): cmux-page://cmux.icon-picker/, built by
    /// scripts/cmux-next/build-pages-web.sh from webviews/src/pages/icon-picker.
    /// `__symbol/<name>.png` are SF Symbols the host draws (IconPickerSymbols).
    static let iconPicker = PageDescriptor(id: "cmux.icon-picker", resource: "icon-picker", namespaces: ["cmux.iconPicker."],
                                           commands: [], dynamicPrefixes: [IconPickerSymbols.prefix])
}

/// One picker use: what the page shows when it opens, and how it ended.
/// Plain values so the open and finish rules are unit tested.
struct IconPickerSession: Equatable {
    /// Echoed by the page's finish, so a late reply never applies to a newer session.
    let id: String
    /// The object's current icon (wire string), if any.
    var current: String?
    /// The first tab: the current icon's kind, else Emoji.
    var tab: String { IconValue(wire: current).map(Self.tab) ?? "emoji" }
    /// Whether Remove Icon shows (the object has an icon now).
    var canClear: Bool { IconValue(wire: current) != nil }
    /// Image and SVG tabs work only when the owner stores assets (the daemon blob store, later).
    var assets = false
    /// The SF Symbol names this Mac draws; sent with the first session of a page only.
    var symbols: [String]?
    /// The newest Emoji version (times 10) the system font draws; sent with `symbols`.
    var maxEmojiVersion: Int?

    private static func tab(_ value: IconValue) -> String {
        switch value {
        case .emoji: "emoji"
        case .symbol: "symbol"
        case .image: "image"
        case .svg: "svg"
        }
    }

    /// The `cmux.iconPicker.session` event.
    var event: JSONValue {
        var members: [String: JSONValue] = [
            "id": .string(id), "tab": .string(tab), "canClear": .bool(canClear), "assets": .bool(assets),
        ]
        if let current { members["value"] = .string(current) }
        if let symbols { members["symbols"] = .array(symbols.map(JSONValue.string)) }
        if let maxEmojiVersion { members["maxEmojiVersion"] = JSONValue(maxEmojiVersion) }
        return .object(members)
    }
}

/// How a picker session ended.
enum IconPickerResult: Equatable {
    /// A new icon (wire string, already checked by ``IconValue``).
    case set(String)
    case clear
    case cancel

    /// The result of a `cmux.iconPicker.finish` call for `session`, or nil when the call is for
    /// another session or carries no valid outcome. An invalid icon is refused, not applied.
    static func decode(_ params: JSONValue, session: String) -> IconPickerResult? {
        guard params["session"]?.stringValue == session else { return nil }
        if let value = params["value"]?.stringValue {
            return IconValue(wire: value).map { .set($0.wire) }
        }
        if params["clear"]?.boolValue == true { return .clear }
        if params["cancel"]?.boolValue == true { return .cancel }
        return nil
    }
}
