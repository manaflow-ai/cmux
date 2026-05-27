import Foundation

struct AgentHookSetupEvidenceDefinition: Sendable {
    let name: String
    let configDir: String
    let configFile: String
    let envOverride: String?
    let envOverrideSubpath: String?
    let disableEnvVar: String
    let markers: [String]
    let isEnabled: @Sendable (UserDefaults) -> Bool

    init(
        name: String,
        configDir: String,
        configFile: String,
        envOverride: String? = nil,
        envOverrideSubpath: String? = nil,
        disableEnvVar: String,
        markers: [String],
        isEnabled: @escaping @Sendable (UserDefaults) -> Bool = { _ in true }
    ) {
        self.name = name
        self.configDir = configDir
        self.configFile = configFile
        self.envOverride = envOverride
        self.envOverrideSubpath = envOverrideSubpath
        self.disableEnvVar = disableEnvVar
        let routedHookMarker = "hooks \(name)"
        self.markers = markers.contains(routedHookMarker) ? markers : markers + [routedHookMarker]
        self.isEnabled = isEnabled
    }

    func isActive(defaults: UserDefaults, environment: [String: String]) -> Bool {
        guard environment[disableEnvVar]?.trimmingCharacters(in: .whitespacesAndNewlines) != "1" else {
            return false
        }
        return isEnabled(defaults)
    }

    func configURL(environment: [String: String], homeDirectory: URL) -> URL {
        let baseURL: URL
        if let envOverride,
           let rawValue = environment[envOverride]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawValue.isEmpty {
            var url = URL(fileURLWithPath: NSString(string: rawValue).expandingTildeInPath, isDirectory: true)
            if let envOverrideSubpath, !envOverrideSubpath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                url.appendPathComponent(envOverrideSubpath, isDirectory: true)
            }
            baseURL = url
        } else {
            baseURL = homeDirectory.appendingPathComponent(configDir, isDirectory: true)
        }
        return Self.appendingRelativePath(configFile, to: baseURL)
    }

    func matchesHookEvidence(in contents: String) -> Bool {
        markers.contains { marker in
            return Self.contents(contents, containsBoundaryAwareMarker: marker)
        }
    }

    private static func contents(_ contents: String, containsBoundaryAwareMarker marker: String) -> Bool {
        guard !marker.isEmpty else { return false }
        var searchRange = contents.startIndex..<contents.endIndex
        while let range = contents.range(of: marker, options: [], range: searchRange) {
            if isMarkerBoundary(contents.character(before: range.lowerBound))
                && isMarkerBoundary(contents.character(at: range.upperBound)) {
                return true
            }
            searchRange = range.upperBound..<contents.endIndex
        }
        return false
    }

    private static func isMarkerBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        return !character.isLetter && !character.isNumber && character != "_" && character != "-"
    }

    private static func appendingRelativePath(_ relativePath: String, to baseURL: URL) -> URL {
        relativePath.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component), isDirectory: false)
        }
    }
}

private extension String {
    func character(before index: Index) -> Character? {
        guard index > startIndex else { return nil }
        return self[self.index(before: index)]
    }

    func character(at index: Index) -> Character? {
        guard index < endIndex else { return nil }
        return self[index]
    }
}
