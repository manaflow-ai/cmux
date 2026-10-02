import Foundation

/// Checks a parsed `cmux-app.json` against `cmux-app.schema.json`
/// (manifest version 1) and reports every issue with its JSON Pointer path.
/// Hand-written for the one schema instead of a generic JSON Schema engine:
/// the rules are few, and readable failures matter more than generality.
/// Unknown top-level keys are errors; unknown keys inside contribution
/// entries are kept and ignored (spec section 3).
nonisolated struct AppManifestValidator {
    private(set) var issues: [AppManifestIssue] = []
    typealias P = AppManifestPatterns

    static let topLevelKeys: Set<String> = [
        "$schema", "manifestVersion", "id", "name", "version", "description", "publisher", "repository", "homepage",
        "license", "icon", "screenshots", "categories", "keywords", "engines", "main", "scopes", "optionalScopes",
        "contributes", "activation", "files", "pricing", "server", "x-cmux-devOnly",
    ]

    static func validate(_ document: AppJSON) -> [AppManifestIssue] {
        var validator = AppManifestValidator()
        validator.root(document)
        return validator.issues
    }

    mutating func fail(_ path: String, _ code: String, _ message: String) {
        issues.append(AppManifestIssue(path: path, code: code, message: message))
    }

    private mutating func root(_ document: AppJSON) {
        guard let object = object(document, at: "") else { return }
        for key in object.keys.sorted() where !Self.topLevelKeys.contains(key) {
            fail("/\(key)", "additionalProperties", "unknown key \(key)")
        }
        for key in ["manifestVersion", "id", "name", "version", "description", "engines"] where object[key] == nil {
            fail("/\(key)", "required", "\(key) is required")
        }
        if let v = object["manifestVersion"], v != .number(1) { fail("/manifestVersion", "const", "manifestVersion must be 1") }
        if let v = object["$schema"] { _ = string(v, at: "/$schema") }
        pattern(object["id"], "/id", P.appID, "an id like publisher/name")
        localizedText(object["name"], "/name")
        pattern(object["version"], "/version", P.semver, "a semver version")
        localizedText(object["description"], "/description")
        if let publisher = object["publisher"] { self.publisher(publisher) }
        pattern(object["repository"], "/repository", P.repository, "a https://github.com/<owner>/<repo> URL")
        pattern(object["homepage"], "/homepage", P.httpsURL, "an https URL", maxLength: 2048)
        if let license = object["license"], let text = string(license, at: "/license"), text.count > 64 {
            fail("/license", "maxLength", "license is longer than 64 characters")
        }
        if let icon = object["icon"] { self.icon(icon) }
        stringArray(object["screenshots"], "/screenshots", maxItems: 8) { this, item, path in this.relativePath(item, path) }
        categories(object["categories"])
        stringArray(object["keywords"], "/keywords", maxItems: 16) { this, item, path in this.maxLength(item, path, 32) }
        if let engines = object["engines"] { self.engines(engines) }
        relativePath(object["main"], "/main")
        scopeMap(object["scopes"], "/scopes")
        scopeMap(object["optionalScopes"], "/optionalScopes")
        if let contributes = object["contributes"] { self.contributes(contributes) }
        if let server = object["server"] { self.server(server) }
        stringArray(object["activation"], "/activation", maxItems: 64) { this, item, path in
            this.pattern(.string(item), path, P.activation, "a known activation event")
        }
        stringArray(object["files"], "/files", maxItems: 64) { this, item, path in this.relativePath(.string(item), path) }
        if let pricing = object["pricing"], pricing != .string("free") { fail("/pricing", "const", "pricing must be \"free\"") }
    }

    private mutating func publisher(_ value: AppJSON) {
        guard let object = object(value, at: "/publisher") else { return }
        for key in object.keys.sorted() where !["name", "url", "email"].contains(key) {
            fail("/publisher/\(key)", "additionalProperties", "unknown key \(key)")
        }
        guard let name = object["name"] else { return fail("/publisher/name", "required", "publisher.name is required") }
        if let text = string(name, at: "/publisher/name") { length(text, "/publisher/name", min: 1, max: 80) }
        pattern(object["url"], "/publisher/url", P.httpsURL, "an https URL", maxLength: 2048)
        if let email = object["email"], let text = string(email, at: "/publisher/email") { length(text, "/publisher/email", min: 0, max: 254) }
    }

    private mutating func icon(_ value: AppJSON) {
        if case .string = value { return relativePath(value, "/icon") }
        guard case .object(let object) = value, let symbol = object["symbol"], object.count == 1 else {
            return fail("/icon", "oneOf", "icon must be a bundle path or {\"symbol\": \"name\"}")
        }
        pattern(symbol, "/icon/symbol", P.symbol, "an SF Symbol name")
    }

    private mutating func categories(_ value: AppJSON?) {
        stringArray(value, "/categories", maxItems: 4) { this, item, path in
            if !P.categories.contains(item) { this.fail(path, "enum", "unknown category \(item)") }
        }
        if let items = value?.arrayValue, Set(items).count != items.count { fail("/categories", "uniqueItems", "categories repeat") }
    }

    private mutating func engines(_ value: AppJSON) {
        guard let object = object(value, at: "/engines") else { return }
        for key in object.keys.sorted() where key != "cmux" { fail("/engines/\(key)", "additionalProperties", "unknown key \(key)") }
        guard let cmux = object["cmux"] else { return fail("/engines/cmux", "required", "engines.cmux is required") }
        if let text = string(cmux, at: "/engines/cmux") { length(text, "/engines/cmux", min: 1, max: 64) }
    }

    private mutating func scopeMap(_ value: AppJSON?, _ path: String) {
        guard let value, let object = object(value, at: path) else { return }
        if object.count > 64 { fail(path, "maxProperties", "more than 64 scopes") }
        for (key, reason) in object.sorted(by: { $0.key < $1.key }) {
            if !P.matches(P.scope, key) { fail("\(path)/\(key)", "propertyName", "\(key) is not a scope name") }
            if let text = string(reason, at: "\(path)/\(key)") { length(text, "\(path)/\(key)", min: 1, max: 200) }
        }
    }

    // MARK: Primitives

    mutating func object(_ value: AppJSON, at path: String) -> [String: AppJSON]? {
        guard case .object(let object) = value else {
            fail(path, "type", "expected an object, found \(value.typeName)")
            return nil
        }
        return object
    }

    mutating func string(_ value: AppJSON, at path: String) -> String? {
        guard case .string(let text) = value else {
            fail(path, "type", "expected a string, found \(value.typeName)")
            return nil
        }
        return text
    }

    mutating func length(_ text: String, _ path: String, min: Int, max: Int) {
        if text.count < min { fail(path, "minLength", "shorter than \(min) characters") }
        if text.count > max { fail(path, "maxLength", "longer than \(max) characters") }
    }

    mutating func maxLength(_ text: String, _ path: String, _ max: Int) { length(text, path, min: 0, max: max) }

    mutating func pattern(_ value: AppJSON?, _ path: String, _ regex: NSRegularExpression, _ expected: String, maxLength: Int? = nil) {
        guard let value, let text = string(value, at: path) else { return }
        if let maxLength, text.count > maxLength { fail(path, "maxLength", "longer than \(maxLength) characters") }
        if !P.matches(regex, text) { fail(path, "pattern", "\"\(text)\" is not \(expected)") }
    }

    mutating func relativePath(_ value: AppJSON?, _ path: String) {
        guard let value, let text = string(value, at: path) else { return }
        length(text, path, min: 1, max: 256)
        if !P.matches(P.relativePath, text) { fail(path, "pattern", "\"\(text)\" is not a relative path inside the package") }
    }

    mutating func relativePath(_ text: String, _ path: String) { relativePath(.string(text), path) }

    mutating func localizedText(_ value: AppJSON?, _ path: String) {
        guard let value else { return }
        switch value {
        case .string(let text): length(text, path, min: 1, max: 300)
        case .object(let object):
            if object["en"] == nil { fail("\(path)/en", "required", "localized text needs an \"en\" value") }
            for (language, text) in object.sorted(by: { $0.key < $1.key }) {
                if !P.matches(P.language, language) { fail("\(path)/\(language)", "propertyName", "\(language) is not a language code") }
                if let text = string(text, at: "\(path)/\(language)") { length(text, "\(path)/\(language)", min: 1, max: 300) }
            }
        default: fail(path, "oneOf", "expected a string or {\"en\": ...}")
        }
    }

    mutating func stringArray(_ value: AppJSON?, _ path: String, maxItems: Int, each: (inout Self, String, String) -> Void) {
        guard let value else { return }
        guard case .array(let items) = value else { return fail(path, "type", "expected an array, found \(value.typeName)") }
        if items.count > maxItems { fail(path, "maxItems", "more than \(maxItems) items") }
        for (index, item) in items.enumerated() {
            if let text = string(item, at: "\(path)/\(index)") { each(&self, text, "\(path)/\(index)") }
        }
    }
}

/// `server`: a long-running app server supervised by the daemon on one host per team.
nonisolated extension AppManifestValidator {
    mutating func server(_ value: AppJSON) {
        let path = "/server"
        guard let object = object(value, at: path) else { return }
        for key in object.keys.sorted() where !["kind", "binary", "args", "catalog", "hosts", "data"].contains(key) {
            fail("\(path)/\(key)", "additionalProperties", "unknown key \(key)")
        }
        if object["kind"] == nil { fail("\(path)/kind", "required", "kind is required") }
        if object["hosts"] == nil { fail("\(path)/hosts", "required", "hosts is required") }
        enumValue(object["kind"], "\(path)/kind", ["native", "js"])
        if object["kind"]?.stringValue == "native", object["binary"] == nil { fail("\(path)/binary", "required", "binary is required") }
        pattern(object["binary"], "\(path)/binary", P.binaryName, "a cmux binary name")
        stringArray(object["args"], "\(path)/args", maxItems: 32) { this, item, path in this.maxLength(item, path, 256) }
        relativePath(object["catalog"], "\(path)/catalog")
        stringArray(object["hosts"], "\(path)/hosts", maxItems: 3) { this, item, path in this.enumValue(.string(item), path, ["local", "team-vm", "cmux-server"]) }
        if object["hosts"]?.arrayValue?.isEmpty == true { fail("\(path)/hosts", "minItems", "hosts needs at least one item") }
        enumValue(object["data"], "\(path)/data", ["durable", "ephemeral"])
    }
}

