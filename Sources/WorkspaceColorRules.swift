import Foundation

struct WorkspaceColorRule: Codable {
    let path: String
    let color: String
}

struct WorkspaceColorRulesConfig: Codable {
    let workspaceColorRules: [WorkspaceColorRule]
}

private struct CompiledColorRule {
    let expandedPath: String
    let compiledRegex: NSRegularExpression?
    let normalizedColor: String
}

@MainActor
enum WorkspaceColorRules {
    private static var compiledRules: [CompiledColorRule] = []
    private static var loaded = false

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/color-rules.json")
    }

    static func reloadRules() {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(WorkspaceColorRulesConfig.self, from: data)
        else {
            compiledRules = []
            loaded = true
            return
        }

        compiledRules = config.workspaceColorRules.compactMap { rule in
            let expanded = (rule.path as NSString).expandingTildeInPath
            guard let color = WorkspaceTabColorSettings.normalizedHex(rule.color) else {
                return nil
            }
            let regex: NSRegularExpression?
            if expanded.contains("*") || expanded.contains("?") {
                let pattern = convertGlobToRegex(expanded)
                regex = try? NSRegularExpression(pattern: pattern)
            } else {
                regex = nil
            }
            return CompiledColorRule(expandedPath: expanded, compiledRegex: regex, normalizedColor: color)
        }
        loaded = true
    }

    static func colorForDirectory(_ directory: String) -> String? {
        if !loaded { reloadRules() }

        let expandedDir = (directory as NSString).expandingTildeInPath

        for rule in compiledRules {
            if matches(directory: expandedDir, rule: rule) {
                return rule.normalizedColor
            }
        }

        return nil
    }

    private static func matches(directory: String, rule: CompiledColorRule) -> Bool {
        if let regex = rule.compiledRegex {
            let range = NSRange(directory.startIndex..., in: directory)
            return regex.firstMatch(in: directory, range: range) != nil
        } else {
            return directory == rule.expandedPath || directory.hasPrefix(rule.expandedPath + "/")
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
                    result += ".*"
                    i = glob.index(after: next)
                    if i < glob.endIndex && glob[i] == "/" {
                        i = glob.index(after: i)
                    }
                    continue
                } else {
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
