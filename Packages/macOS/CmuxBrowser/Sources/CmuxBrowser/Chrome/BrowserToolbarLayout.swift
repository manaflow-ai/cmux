public import Foundation

/// One customizable button in the browser toolbar's trailing area.
///
/// The More Actions menu is not an item: it always stays last so every hidden
/// button remains reachable through "Customize Toolbar…".
public enum BrowserToolbarItem: Hashable, Sendable {
    case designMode
    case profile
    case theme
    case extensions
    case devTools
    /// A Chrome extension's action, pinned beside the extensions button.
    case pinnedExtension(String)

    /// The built-in buttons, in their default order.
    public static let builtIns: [BrowserToolbarItem] = [.designMode, .profile, .theme, .extensions, .devTools]

    private static let extensionPrefix = "extension:"

    /// The string stored in `cmux.json` and user defaults.
    public var storageValue: String {
        switch self {
        case .designMode: return "designMode"
        case .profile: return "profile"
        case .theme: return "theme"
        case .extensions: return "extensions"
        case .devTools: return "devTools"
        case .pinnedExtension(let id): return Self.extensionPrefix + id
        }
    }

    /// Parses a stored value. Unknown values and malformed extension ids
    /// return `nil`, so a hand-edited `cmux.json` cannot inject arbitrary ids.
    public init?(storageValue: String) {
        switch storageValue {
        case "designMode": self = .designMode
        case "profile": self = .profile
        case "theme": self = .theme
        case "extensions": self = .extensions
        case "devTools": self = .devTools
        default:
            guard storageValue.hasPrefix(Self.extensionPrefix) else { return nil }
            let id = String(storageValue.dropFirst(Self.extensionPrefix.count))
            guard ChromeExtensionPackage.isExtensionID(id) || ChromeExtensionsManagerPage.isLocalExtensionID(id) else {
                return nil
            }
            self = .pinnedExtension(id)
        }
    }
}

/// The ordered, visible buttons of the browser toolbar's trailing area.
///
/// Persisted as newline-separated storage values under ``userDefaultsKey``,
/// the same encoding `cmux.json` string-array settings use. A missing value
/// means the default layout; an empty value means every button is hidden.
public struct BrowserToolbarLayout: Equatable, Sendable {
    public static let userDefaultsKey = "browserToolbarItems"
    public static let `default` = BrowserToolbarLayout(items: BrowserToolbarItem.builtIns)

    /// Visible items, left to right. Never contains duplicates.
    public private(set) var items: [BrowserToolbarItem]

    public init(items: [BrowserToolbarItem]) {
        var seen = Set<BrowserToolbarItem>()
        self.items = items.filter { seen.insert($0).inserted }
    }

    /// Decodes a stored value; `nil` yields the default layout.
    public init(storedValue: String?) {
        guard let storedValue else {
            self = .default
            return
        }
        self.init(items: storedValue
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap(BrowserToolbarItem.init(storageValue:)))
    }

    public var storedValue: String {
        items.map(\.storageValue).joined(separator: "\n")
    }

    public func contains(_ item: BrowserToolbarItem) -> Bool {
        items.contains(item)
    }

    /// Built-in buttons that are currently hidden, in default order.
    public var hiddenBuiltIns: [BrowserToolbarItem] {
        BrowserToolbarItem.builtIns.filter { !items.contains($0) }
    }

    public mutating func hide(_ item: BrowserToolbarItem) {
        items.removeAll { $0 == item }
    }

    /// Shows a hidden item. A built-in returns to its default position
    /// relative to the visible built-ins; a pinned extension goes right after
    /// the extensions button, or at the end when that button is hidden.
    public mutating func show(_ item: BrowserToolbarItem) {
        guard !items.contains(item) else { return }
        switch item {
        case .pinnedExtension:
            if let index = items.firstIndex(of: .extensions) {
                let lastPinned = items[(index + 1)...].prefix { if case .pinnedExtension = $0 { return true } else { return false } }.count
                items.insert(item, at: index + 1 + lastPinned)
            } else {
                items.append(item)
            }
        default:
            let order = BrowserToolbarItem.builtIns
            guard let rank = order.firstIndex(of: item) else { return items.append(item) }
            let insertion = items.firstIndex { other in
                guard let otherRank = order.firstIndex(of: other) else { return false }
                return otherRank > rank
            } ?? items.count
            items.insert(item, at: insertion)
        }
    }

    public mutating func setVisible(_ item: BrowserToolbarItem, _ visible: Bool) {
        if visible { show(item) } else { hide(item) }
    }

    /// Moves `item` one place left (`offset` -1) or right (`offset` +1).
    public mutating func move(_ item: BrowserToolbarItem, by offset: Int) {
        guard let index = items.firstIndex(of: item) else { return }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
    }

    public func canMove(_ item: BrowserToolbarItem, by offset: Int) -> Bool {
        guard let index = items.firstIndex(of: item) else { return false }
        return items.indices.contains(index + offset)
    }

    /// Reorders visible items, with the semantics of SwiftUI's `onMove`.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { items[$0] }
        var remaining = items.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let adjusted = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(max(adjusted, 0), remaining.count))
        items = remaining
    }

    /// Drops pinned extensions that are no longer installed.
    public mutating func removePinned(notIn installedIDs: Set<String>) {
        items.removeAll { item in
            if case .pinnedExtension(let id) = item { return !installedIDs.contains(id) }
            return false
        }
    }

    public static func load(from defaults: UserDefaults = .standard) -> BrowserToolbarLayout {
        BrowserToolbarLayout(storedValue: defaults.string(forKey: userDefaultsKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        if self == .default {
            defaults.removeObject(forKey: Self.userDefaultsKey)
        } else {
            defaults.set(storedValue, forKey: Self.userDefaultsKey)
        }
    }
}
