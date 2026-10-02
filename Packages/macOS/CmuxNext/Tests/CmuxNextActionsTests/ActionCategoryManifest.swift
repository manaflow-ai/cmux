import CmuxNextActions
import Foundation

/// The catalog's action ids by category, as stable JSON (category keys and
/// ids sorted), for `ActionCatalogTests.everyActionIsInTheCategoryManifest`.
struct ActionCategoryManifest {
    let ids: [ActionCategory: Set<String>]

    init(_ descriptors: [ActionDescriptor]) {
        var ids: [ActionCategory: Set<String>] = [:]
        for descriptor in descriptors { ids[descriptor.category, default: []].insert(descriptor.id.rawValue) }
        self.ids = ids
    }

    init(json: Data) throws {
        let decoded = try JSONDecoder().decode([String: [String]].self, from: json)
        var ids: [ActionCategory: Set<String>] = [:]
        for (key, list) in decoded {
            guard let category = ActionCategory(rawValue: key) else {
                throw CocoaError(.coderInvalidValue, userInfo: [NSDebugDescriptionErrorKey: "unknown category \(key)"])
            }
            ids[category] = Set(list)
        }
        self.ids = ids
    }

    var json: String {
        let root = Dictionary(uniqueKeysWithValues: ids.map { ($0.key.rawValue, $0.value.sorted()) })
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text + "\n"
    }
}
