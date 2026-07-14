import Foundation

/// `{{placeholder}}` scanning and substitution for prompt templates and
/// agent command templates.
///
/// Placeholders are lowercase identifiers wrapped in double braces, with
/// optional inner whitespace: `{{task}}`, `{{ repo_root }}`. Rendering is
/// strict: a placeholder that is neither a built-in nor a template parameter
/// is an error, so typos fail at validate/plan time instead of producing a
/// prompt with literal `{{...}}` residue.
public struct OrchestrationPlaceholders: Sendable {
    public init() {}

    /// Built-in placeholder names cmux provides per task at run time.
    /// Template parameters may not shadow these.
    public static let builtins: Set<String> = [
        "task",
        "task_index",
        "task_slug",
        "branch",
        "workspace_dir",
        "issue_number",
        "orchestration_name",
        "run_id",
    ]

    /// Additional placeholders valid only inside agent command templates.
    public static let commandOnlyBuiltins: Set<String> = [
        "prompt",
        "prompt_file",
    ]

    /// Returns the distinct placeholder names appearing in `template`, in
    /// first-appearance order.
    public func scan(_ template: String) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        forEachToken(in: template) { token in
            if case .placeholder(let name) = token, !seen.contains(name) {
                seen.insert(name)
                names.append(name)
            }
        }
        return names
    }

    /// Substitutes placeholders from `values`. Throws when the template
    /// references a name absent from `values`.
    public func render(_ template: String, values: [String: String]) throws -> String {
        var output = ""
        var missing: [String] = []
        forEachToken(in: template) { token in
            switch token {
            case .literal(let text):
                output.append(text)
            case .placeholder(let name):
                if let value = values[name] {
                    output.append(value)
                } else if !missing.contains(name) {
                    missing.append(name)
                }
            }
        }
        guard missing.isEmpty else {
            throw OrchestrationManifestError(
                message: "Unresolved placeholder(s): \(missing.map { "{{\($0)}}" }.joined(separator: ", "))"
            )
        }
        return output
    }

    /// Wraps `text` in single quotes for safe inclusion in a shell command
    /// typed into a terminal (`'` becomes `'\''`).
    public func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Lowercases `text` and squeezes everything but ASCII alphanumerics
    /// into single hyphens — used for branch and directory names.
    public func slug(_ text: String, maxLength: Int = 40) -> String {
        var result = ""
        var previousWasHyphen = true
        for character in text.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                result.append(character)
                previousWasHyphen = false
            } else if !previousWasHyphen {
                result.append("-")
                previousWasHyphen = true
            }
            if result.count >= maxLength { break }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    private enum Token {
        case literal(String)
        case placeholder(String)
    }

    /// Tokenizes `template` into literals and placeholders. Malformed braces
    /// (`{{not closed`, `{{Bad Name}}`) stay literal text.
    private func forEachToken(in template: String, _ body: (Token) -> Void) {
        var literal = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{",
               let name = placeholderName(in: template, openingAt: index) {
                if !literal.isEmpty {
                    body(.literal(literal))
                    literal = ""
                }
                body(.placeholder(name.name))
                index = name.end
            } else {
                literal.append(template[index])
                index = template.index(after: index)
            }
        }
        if !literal.isEmpty {
            body(.literal(literal))
        }
    }

    private func placeholderName(
        in template: String,
        openingAt start: String.Index
    ) -> (name: String, end: String.Index)? {
        var index = start
        guard template[index] == "{" else { return nil }
        index = template.index(after: index)
        guard index < template.endIndex, template[index] == "{" else { return nil }
        index = template.index(after: index)
        var name = ""
        while index < template.endIndex, template[index] == " " {
            index = template.index(after: index)
        }
        while index < template.endIndex {
            let character = template[index]
            if character == " " || character == "}" { break }
            guard character.isASCII,
                  (character.isLowercase && character.isLetter) || character.isNumber || character == "_"
            else { return nil }
            name.append(character)
            index = template.index(after: index)
        }
        while index < template.endIndex, template[index] == " " {
            index = template.index(after: index)
        }
        guard !name.isEmpty,
              let first = name.first, first.isLetter,
              index < template.endIndex, template[index] == "}"
        else { return nil }
        index = template.index(after: index)
        guard index < template.endIndex, template[index] == "}" else { return nil }
        return (name, template.index(after: index))
    }
}
