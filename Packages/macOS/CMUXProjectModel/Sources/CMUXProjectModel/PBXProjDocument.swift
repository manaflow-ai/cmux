import Foundation

/// Read-only view of the object graph in a `project.pbxproj`.
///
/// `PropertyListSerialization` reads the OpenStep text format Xcode writes (and
/// the XML and JSON variants some tools emit), so the graph is a dictionary of
/// objects keyed by their 24-character identifier. Every value is a string, an
/// array, or a nested dictionary; this type adds the typed lookups and the
/// group-relative path resolution the adapter needs.
struct PBXProjDocument {
    typealias Object = [String: Any]

    enum LoadError: Error, CustomStringConvertible {
        case notADictionary
        case missingObjects
        case missingRootObject

        var description: String {
            switch self {
            case .notADictionary: return "project.pbxproj is not a property list dictionary"
            case .missingObjects: return "project.pbxproj has no objects table"
            case .missingRootObject: return "missing rootObject"
            }
        }
    }

    let objects: [String: Object]
    let rootObjectID: String

    /// Identifier of the group that lists each element as a child.
    private let parents: [String: String]
    private let mainGroupIDs: Set<String>

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let root = plist as? [String: Any] else { throw LoadError.notADictionary }
        guard let objects = root["objects"] as? [String: Object] else { throw LoadError.missingObjects }
        guard let rootObjectID = root["rootObject"] as? String, objects[rootObjectID] != nil else {
            throw LoadError.missingRootObject
        }
        self.objects = objects
        self.rootObjectID = rootObjectID

        var parents: [String: String] = [:]
        var mainGroupIDs: Set<String> = []
        for (id, object) in objects {
            if object["isa"] as? String == "PBXProject", let mainGroup = object["mainGroup"] as? String {
                mainGroupIDs.insert(mainGroup)
            }
            for child in object["children"] as? [String] ?? [] where parents[child] == nil {
                parents[child] = id
            }
        }
        self.parents = parents
        self.mainGroupIDs = mainGroupIDs
    }

    var rootObject: Object { objects[rootObjectID] ?? [:] }

    func isa(_ id: String) -> String? {
        objects[id]?["isa"] as? String
    }

    func string(_ key: String, of id: String) -> String? {
        objects[id]?[key] as? String
    }

    /// The identifiers under `key`, dropping any that name no object.
    func references(_ key: String, of id: String) -> [String] {
        (objects[id]?[key] as? [String] ?? []).filter { objects[$0] != nil }
    }

    /// The identifier under `key`, or nil when it names no object.
    func reference(_ key: String, of id: String) -> String? {
        guard let target = string(key, of: id), objects[target] != nil else { return nil }
        return target
    }

    /// Build configurations of the configuration list that `ownerID` points at.
    func buildConfigurations(of ownerID: String) -> [String] {
        guard let list = reference("buildConfigurationList", of: ownerID) else { return [] }
        return references("buildConfigurations", of: list)
    }

    func buildSettings(of configurationID: String) -> [String: Any] {
        objects[configurationID]?["buildSettings"] as? [String: Any] ?? [:]
    }

    // MARK: - Path resolution

    /// Absolute path of a file element, following `<group>` source trees up to
    /// the project directory. Returns nil for source trees that only a build can
    /// resolve (`BUILT_PRODUCTS_DIR`, `SDKROOT`, `DEVELOPER_DIR`).
    func fullPath(of id: String, sourceRoot: String) -> String? {
        var visited: Set<String> = []
        return fullPath(of: id, sourceRoot: sourceRoot, asContainer: false, visited: &visited)
    }

    /// `asContainer` resolves the directory a group's children are relative to.
    /// That differs from the group's own path only for a variant group, which
    /// stands for its Base child's file but contains files beside that file.
    private func fullPath(
        of id: String,
        sourceRoot: String,
        asContainer: Bool,
        visited: inout Set<String>
    ) -> String? {
        guard visited.insert(id).inserted else { return nil }
        let path = string("path", of: id)
        switch string("sourceTree", of: id) {
        case "<absolute>":
            return path
        case "SOURCE_ROOT":
            return path.map { Self.join(sourceRoot, $0) }
        case "<group>":
            let groupPath: String
            if let parent = parents[id] {
                groupPath = fullPath(of: parent, sourceRoot: sourceRoot, asContainer: true, visited: &visited)
                    ?? sourceRoot
            } else if mainGroupIDs.contains(id) {
                return path.map { Self.join(sourceRoot, $0) } ?? sourceRoot
            } else {
                return nil
            }
            let representsBaseChild = isa(id) == "PBXVariantGroup" && !asContainer
            let relative = representsBaseChild ? baseVariantPath(of: id) : path
            return relative.map { Self.join(groupPath, $0) } ?? groupPath
        default:
            return nil
        }
    }

    private func baseVariantPath(of id: String) -> String? {
        references("children", of: id)
            .first { string("name", of: $0) == "Base" }
            .flatMap { string("path", of: $0) }
    }

    /// Joins two paths the way Xcode resolves a group-relative path: an absolute
    /// right side wins, `.` components drop out, and leading `..` on the right
    /// consumes trailing components on the left without climbing above `/`.
    static func join(_ lhs: String, _ rhs: String) -> String {
        if rhs.hasPrefix("/") { return rhs }
        var left = (lhs as NSString).pathComponents
        var right = (rhs as NSString).pathComponents
        if left.count > 1, left.last == "/" { left.removeLast() }
        left.removeAll { $0 == "." }
        right.removeAll { $0 == "." }
        while let last = left.last, last != "..", right.first == ".." {
            if left.count > 1 || last != "/" { left.removeLast() }
            right.removeFirst()
        }
        let components = left + right
        if components.isEmpty { return "." }
        let joined = components.joined(separator: "/")
        if components.first == "/", components.count > 1 { return String(joined.dropFirst()) }
        return joined
    }
}
