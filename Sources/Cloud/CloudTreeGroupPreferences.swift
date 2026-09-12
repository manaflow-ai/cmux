import Foundation

/// Persistent visibility and order for resource groups in the Cloud tree.
/// The same store is used by the context menu, CLI, and settings.json loader.
enum CloudTreeGroupPreferences {
    enum Group: String, CaseIterable, Codable, Sendable {
        case workspaces, terminals, browsers, displays, ports, agents
    }

    static let orderKey = "cloudTree.groups.order"
    static let hiddenKey = "cloudTree.groups.hidden"
    static let didChangeNotification = Notification.Name("cmux.cloudTree.groupsDidChange")

    static func ordered(defaults: UserDefaults = .standard) -> [Group] {
        let stored = (defaults.stringArray(forKey: orderKey) ?? []).compactMap(Group.init(rawValue:))
        return stored + Group.allCases.filter { !stored.contains($0) }
    }

    static func hidden(defaults: UserDefaults = .standard) -> Set<Group> {
        Set((defaults.stringArray(forKey: hiddenKey) ?? []).compactMap(Group.init(rawValue:)))
    }

    static func isVisible(_ group: Group, defaults: UserDefaults = .standard) -> Bool {
        !hidden(defaults: defaults).contains(group)
    }

    @discardableResult
    static func setVisible(_ visible: Bool, group: Group, defaults: UserDefaults = .standard) -> Bool {
        var values = hidden(defaults: defaults)
        if visible { values.remove(group) } else { values.insert(group) }
        guard values.count < Group.allCases.count else { return false }
        defaults.set(values.map(\.rawValue).sorted(), forKey: hiddenKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        return true
    }

    static func setOrder(_ groups: [Group], defaults: UserDefaults = .standard) {
        let normalized = groups + Group.allCases.filter { !groups.contains($0) }
        defaults.set(normalized.map(\.rawValue), forKey: orderKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
