import Foundation

struct WorkspaceColorRule: Codable {
    let path: String
    let color: String
}

struct WorkspaceColorRulesConfig: Codable {
    let workspaceColorRules: [WorkspaceColorRule]
}

enum WorkspaceColorRules {
    private static var rules: [WorkspaceColorRule] = []
    private static var loaded = false

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/color-rules.json")
    }

    static func reloadRules() {
        guard FileManager.default.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(WorkspaceColorRulesConfig.self, from: data)
        else {
            rules = []
            loaded = true
            return
        }

        rules = config.workspaceColorRules
        loaded = true
    }

    static func colorForDirectory(_ directory: String) -> String? {
        if !loaded { reloadRules() }

        let expandedDir = expandTilde(directory)

        for rule in rules {
            let expandedPattern = expandTilde(rule.path)
            if matchesPattern(directory: expandedDir, pattern: expandedPattern) {
                return WorkspaceTabColorSettings.normalizedHex(rule.color)
            }
        }

        return nil
    }

    private static func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path
                + String(path.dropFirst(1))
        }
        return path
    }

    private static func matchesPattern(directory: String, pattern: String) -> Bool {
        if pattern.contains("*") {
            let regexPattern = convertGlobToRegex(pattern)
            return directory.range(of: regexPattern, options: .regularExpression) != nil
        } else {
            return directory == pattern || directory.hasPrefix(pattern + "/")
        }
    }

    private static func convertGlobToRegex(_ glob: String) -> String {
        var result = "^"
        var i = glob.startIndex

        while i < glob.endIndex {
            let c = glob[i]
            if c == "*" {
                let next = glob.index(after: i)
                if next < glob.endIndex && glob[next] == "*" {
                    // ** matches any path including separators
                    result += ".*"
                    i = glob.index(after: next)
                    // Skip trailing / after **
                    if i < glob.endIndex && glob[i] == "/" {
                        i = glob.index(after: i)
                    }
                    continue
                } else {
                    // * matches anything except /
                    result += "[^/]*"
                }
            } else if c == "?" {
                result += "[^/]"
            } else if ".+^${}()|[]\\".contains(c) {
                result += "\\\(c)"
            } else {
                result.append(c)
            }
            i = glob.index(after: i)
        }

        result += "(/.*)?$"
        return result
    }
}
