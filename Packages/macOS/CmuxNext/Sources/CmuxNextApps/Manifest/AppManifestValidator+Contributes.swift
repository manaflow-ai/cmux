import Foundation

/// `contributes` rules: one entry shape per contribution kind.
nonisolated extension AppManifestValidator {
    /// Per kind: max entries, required keys, and checks for known keys.
    private struct Kind {
        let maxItems: Int
        let required: [String]
    }

    private static let kinds: [String: Kind] = [
        "sidebarSections": Kind(maxItems: 16, required: ["id", "title", "render"]),
        "commands": Kind(maxItems: 64, required: ["id", "title", "run"]),
        "statusItems": Kind(maxItems: 4, required: ["id", "render"]),
        "sidebars": Kind(maxItems: 4, required: ["id", "title", "render"]),
        "paneKinds": Kind(maxItems: 8, required: ["id", "title"]),
        "themes": Kind(maxItems: 32, required: ["id", "title"]),
        "skills": Kind(maxItems: 32, required: ["id", "path"]),
        "agents": Kind(maxItems: 8, required: ["id", "title", "command"]),
        "mcpServers": Kind(maxItems: 4, required: ["id"]),
        "automations": Kind(maxItems: 16, required: ["id", "title", "template"]),
        "automationTriggers": Kind(maxItems: 32, required: ["id", "title", "event"]),
        "paletteScopes": Kind(maxItems: 16, required: ["id", "title"]),
    ]

    mutating func contributes(_ value: AppJSON) {
        guard let object = object(value, at: "/contributes") else { return }
        for (key, entries) in object.sorted(by: { $0.key < $1.key }) {
            let path = "/contributes/\(key)"
            if key == "settings" {
                settings(entries)
                continue
            }
            guard let kind = Self.kinds[key] else {
                fail(path, "additionalProperties", "unknown contribution kind \(key)")
                continue
            }
            guard case .array(let items) = entries else {
                fail(path, "type", "expected an array, found \(entries.typeName)")
                continue
            }
            if items.count > kind.maxItems { fail(path, "maxItems", "more than \(kind.maxItems) \(key)") }
            for (index, item) in items.enumerated() {
                entry(item, kind: key, required: kind.required, path: "\(path)/\(index)")
            }
        }
    }

    private mutating func entry(_ value: AppJSON, kind: String, required: [String], path: String) {
        guard let object = object(value, at: path) else { return }
        for key in required where object[key] == nil { fail("\(path)/\(key)", "required", "\(key) is required") }
        pattern(object["id"], "\(path)/id", P.contributionID, "a contribution id")
        localizedText(object["title"], "\(path)/title")
        pattern(object["symbol"], "\(path)/symbol", P.symbol, "an SF Symbol name")
        for key in ["render", "run"] { pattern(object[key], "\(path)/\(key)", P.exportName, "an export name") }
        switch kind {
        case "sidebarSections":
            enumValue(object["defaultRegion"], "\(path)/defaultRegion", ["top", "middle", "bottom"])
            enumValue(object["look"], "\(path)/look", ["builtIn", "list"])
            integer(object["maxRows"], "\(path)/maxRows", 1...50)
        case "commands":
            stringArray(object["keywords"], "\(path)/keywords", maxItems: 16) { this, item, path in this.maxLength(item, path, 32) }
            stringArray(object["contexts"], "\(path)/contexts", maxItems: 16) { this, item, path in
                this.pattern(.string(item), path, P.commandContext, "a command context")
            }
            if let arguments = object["arguments"] { _ = self.object(arguments, at: "\(path)/arguments") }
            enumValue(object["view"], "\(path)/view", ["none", "list", "detail", "form"])
            if let destructive = object["destructive"], destructive.boolValue == nil { fail("\(path)/destructive", "type", "expected a boolean") }
        case "statusItems":
            enumValue(object["placement"], "\(path)/placement", ["titlebar", "roomBar", "statusStrip"])
        case "paneKinds":
            relativePath(object["web"], "\(path)/web")
            if let csp = object["csp"], let text = string(csp, at: "\(path)/csp") { maxLength(text, "\(path)/csp", 1024) }
            enumValue(object["renderer"], "\(path)/renderer", ["declarative", "web", "native"])
            pattern(object["nativeView"], "\(path)/nativeView", P.nativeView, "a native view id")
            let native = object["renderer"]?.stringValue == "native" && object["nativeView"] != nil
            let shapes = [object["render"] != nil, object["web"] != nil, native].filter { $0 }.count
            if shapes != 1 { fail(path, "oneOf", "a pane kind needs exactly one of render, web, or renderer native with nativeView") }
        case "themes":
            relativePath(object["ghostty"], "\(path)/ghostty")
            enumValue(object["appearance"], "\(path)/appearance", ["light", "dark", "any"])
            if let chrome = object["chrome"], let colors = self.object(chrome, at: "\(path)/chrome") {
                for (key, color) in colors.sorted(by: { $0.key < $1.key }) {
                    pattern(color, "\(path)/chrome/\(key)", P.hexColor, "a #RRGGBB color")
                }
            }
        case "skills":
            relativePath(object["path"], "\(path)/path")
        case "agents":
            stringArray(object["command"], "\(path)/command", maxItems: 32) { _, _, _ in }
            if object["command"]?.arrayValue?.isEmpty == true { fail("\(path)/command", "minItems", "command needs at least one item") }
            enumValue(object["protocol"], "\(path)/protocol", ["acp"])
        case "mcpServers":
            enumValue(object["tools"], "\(path)/tools", ["commands", "main", "catalog"])
            pattern(object["group"], "\(path)/group", P.mcpGroup, "an MCP group name")
            pattern(object["url"], "\(path)/url", P.httpsURL, "an https URL", maxLength: 2048)
        case "automations":
            relativePath(object["template"], "\(path)/template")
        case "paletteScopes":
            localizedText(object["placeholder"], "\(path)/placeholder")
            pattern(object["prefix"], "\(path)/prefix", P.palettePrefix, "a short lowercase prefix")
        case "automationTriggers":
            pattern(object["event"], "\(path)/event", P.eventName, "a catalog event name")
            if let schema = object["payloadSchema"] { _ = self.object(schema, at: "\(path)/payloadSchema") }
        default:
            break
        }
    }

    private mutating func settings(_ value: AppJSON) {
        let path = "/contributes/settings"
        guard let object = object(value, at: path) else { return }
        if object["type"] == nil { fail("\(path)/type", "required", "type is required") }
        if object["properties"] == nil { fail("\(path)/properties", "required", "properties is required") }
        if let type = object["type"], type != .string("object") { fail("\(path)/type", "const", "type must be \"object\"") }
        if let properties = object["properties"] { _ = self.object(properties, at: "\(path)/properties") }
    }

    mutating func enumValue(_ value: AppJSON?, _ path: String, _ allowed: Set<String>) {
        guard let value, let text = string(value, at: path) else { return }
        if !allowed.contains(text) { fail(path, "enum", "\(text) is not one of \(allowed.sorted().joined(separator: ", "))") }
    }

    private mutating func integer(_ value: AppJSON?, _ path: String, _ range: ClosedRange<Int>) {
        guard let value else { return }
        guard case .number(let number) = value, number.rounded() == number else { return fail(path, "type", "expected an integer") }
        if Double(range.lowerBound) > number { fail(path, "minimum", "less than \(range.lowerBound)") }
        if Double(range.upperBound) < number { fail(path, "maximum", "more than \(range.upperBound)") }
    }
}
