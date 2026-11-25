public import CmuxNextDesign
import Foundation

/// One row's reads from Rust's `schema.rows` (cmux-tui/crates/cmux-config/src/app_ops/schema_rows.rs):
/// what ``SettingDescriptor/storedValue(in:)``, ``SettingDescriptor/effectiveValue(in:)``,
/// ``SettingDescriptor/isCustomized(in:)``, ``SettingDescriptor/toggledValue(in:)`` and
/// ``SettingDescriptor/inheritedValue(in:)`` answer, read for many rows in one call.
public nonisolated struct SettingRowRead: Sendable, Equatable {
    public let stored: JSONValue?
    public let effective: JSONValue?
    public let customized: Bool
    public let toggled: Bool?
    public let inherited: JSONValue?
    /// The `options` and `summary` members `schema.palette_options` answers, when the palette was asked.
    let palette: JSONValue?
}

/// The palette half of a ``SettingsSchema/reads(root:storedRoot:keys:palette:)`` request.
public nonisolated struct SettingPaletteReads: Sendable {
    /// The theme's colors, offered as swatches for a color row.
    public var themeColors: [ThemeRGB]
    /// The values the palette shows instead of the effective one (a write not landed yet), by key;
    /// nil unsets the key.
    public var current: [String: JSONValue?]

    public init(themeColors: [ThemeRGB], current: [String: JSONValue?] = [:]) {
        self.themeColors = themeColors
        self.current = current
    }

    var request: JSONValue {
        [
            "theme_colors": .array(themeColors.map(\.rustRequest)),
            "current": .object(current.mapValues { $0 ?? .null }),
        ]
    }
}

extension SettingsSchema {
    /// Each row's reads by key, in one Rust call (two when a row needs the art catalog or a background
    /// resolved first: every such id is asked at once). `stored` and `customized` read `storedRoot`
    /// (`root` when nil); the rest read `root`. `keys` nil reads every row.
    public static func reads(root: JSONValue, storedRoot: JSONValue? = nil, keys: [String]? = nil,
                             palette: SettingPaletteReads? = nil) -> [String: SettingRowRead] {
        var request: [String: JSONValue] = ["root": root]
        if let storedRoot { request["stored_root"] = storedRoot }
        if let keys { request["keys"] = .array(keys.map(JSONValue.string)) }
        if let palette { request["palette"] = palette.request }
        var reply = SettingsRust.answer("schema.rows", .object(request))
        // An art resolves to a stored value, whose background may then need resolving: two asks at most.
        for _ in 0..<2 {
            guard let need = reply["need"] else { break }
            var arts = request["arts"]?.objectValue ?? [:]
            for id in need["arts"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                arts[id] = BackdropArt(id: id).map { .string($0.rawValue) } ?? .null
            }
            request["arts"] = .object(arts)
            if case .object(var asked)? = request["palette"] {
                var selections = asked["selections"]?.objectValue ?? [:]
                for raw in need["selections"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                    selections[raw] = BackdropSelection(id: raw).map { ["id": .string($0.id), "title": .string($0.title)] } ?? .null
                }
                asked["selections"] = .object(selections)
                request["palette"] = .object(asked)
            }
            reply = SettingsRust.answer("schema.rows", .object(request))
        }
        var reads: [String: SettingRowRead] = [:]
        for row in reply["rows"]?.arrayValue ?? [] {
            guard let key = row["key"]?.stringValue else { continue }
            let palette: JSONValue? = row["options"].map { ["options": $0, "summary": row["summary"] ?? .null] }
            reads[key] = SettingRowRead(
                stored: SettingDescriptor.present(row["stored"]), effective: SettingDescriptor.present(row["effective"]),
                customized: row["customized"]?.boolValue ?? false, toggled: row["toggled"]?.boolValue,
                inherited: SettingDescriptor.present(row["inherited"]), palette: palette)
        }
        return reads
    }

    /// Each row's stored value in `root` by key (``SettingDescriptor/storedValue(in:)``), in one call.
    public static func storedValues(in root: JSONValue) -> [String: JSONValue] {
        reads(root: root).compactMapValues(\.stored)
    }

    /// The keys whose ``storedValues(in:)`` differ between two roots, in schema order.
    public static func changedKeys(_ was: [String: JSONValue], _ now: [String: JSONValue]) -> [String] {
        all.filter { was[$0.id] != now[$0.id] }.map(\.id)
    }
}

extension SettingsController {
    /// The palette rows' reads in one `schema.rows` call, each with the value the palette shows: a
    /// pending write not landed yet (its value nil: the row's default), else the effective value.
    public func paletteReads(_ listed: [SettingDescriptor], pending: [String: JSONValue?],
                             themeColors: [ThemeRGB]) -> [String: (read: SettingRowRead, current: JSONValue?)] {
        var current: [String: JSONValue?] = [:]
        for descriptor in listed {
            // updateValue keeps a nil (unset) entry, which a subscript assignment would remove.
            if let write = pending[descriptor.id] { current.updateValue(write ?? defaultValue(of: descriptor), forKey: descriptor.id) }
        }
        let reads = SettingsSchema.reads(root: snapshot.root, keys: listed.map(\.id),
                                         palette: SettingPaletteReads(themeColors: themeColors, current: current))
        return reads.reduce(into: [:]) { $0[$1.key] = ($1.value, current[$1.key] ?? $1.value.effective) }
    }
}

extension ThemeRGB {
    /// The color as a Rust request member: `{red, green, blue, alpha}` in 0...1.
    nonisolated var rustRequest: JSONValue {
        ["red": .number(red), "green": .number(green), "blue": .number(blue), "alpha": .number(alpha)]
    }
}
