import Foundation

extension DockExtensionManifest {
    /// Parses and validates a `cmux-extension.json` document.
    ///
    /// Validation is strict inside known objects (an unknown key on a pane or
    /// build step is an error) but tolerant at the top level (an unknown
    /// top-level key — e.g. a future `actions` section — is recorded in
    /// ``unknownTopLevelKeys`` and surfaced as a warning), so manifests written
    /// for a newer cmux still install.
    ///
    /// - Throws: ``DockExtensionError/manifestTooLarge(limitBytes:)``,
    ///   ``DockExtensionError/unsupportedManifestVersion(_:)``, or
    ///   ``DockExtensionError/manifestInvalid(_:)`` listing every field error.
    public static func parse(data: Data) throws -> DockExtensionManifest {
        guard data.count <= maximumFileSize else {
            throw DockExtensionError.manifestTooLarge(limitBytes: maximumFileSize)
        }
        let rootObject: Any
        do {
            rootObject = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw DockExtensionError.manifestInvalid(["not valid JSON: \(error.localizedDescription)"])
        }
        guard let root = rootObject as? [String: Any] else {
            throw DockExtensionError.manifestInvalid(["top level must be a JSON object"])
        }

        guard let manifestVersion = intValue(root["manifestVersion"]) else {
            throw DockExtensionError.manifestInvalid(["\"manifestVersion\" is required and must be an integer"])
        }
        guard manifestVersion == supportedManifestVersion else {
            throw DockExtensionError.unsupportedManifestVersion(manifestVersion)
        }

        var errors: [String] = []

        let id = requiredString(root, key: "id", maxLength: 64, errors: &errors)
        if let id, !isValidExtensionId(id) {
            errors.append("\"id\" may only contain ASCII letters, digits, '.', '_', ':', '-' (and not dots only)")
        }
        let name = requiredString(root, key: "name", maxLength: 100, errors: &errors)
        let version = requiredString(root, key: "version", maxLength: 32, errors: &errors)
        let description = optionalString(root, key: "description", maxLength: 500, errors: &errors)

        var minCmuxVersion: DockExtensionVersion?
        if let raw = optionalString(root, key: "minCmuxVersion", maxLength: 32, errors: &errors) {
            if let parsed = DockExtensionVersion(raw) {
                minCmuxVersion = parsed
            } else {
                errors.append("\"minCmuxVersion\" must be 1–4 dot-separated numbers (e.g. \"0.30.0\")")
            }
        }

        let platforms = optionalStringArray(root, key: "platforms", errors: &errors)
        let icon = optionalString(root, key: "icon", maxLength: 64, errors: &errors)
        let build = parseBuildSteps(root["build"], errors: &errors)
        let panes = parsePanes(root["panes"], errors: &errors)

        let knownKeys: Set<String> = [
            "$schema", "manifestVersion", "id", "name", "version", "description",
            "minCmuxVersion", "platforms", "icon", "build", "panes",
        ]
        let unknownTopLevelKeys = root.keys.filter { !knownKeys.contains($0) }.sorted()

        guard errors.isEmpty, let id, let name, let version else {
            throw DockExtensionError.manifestInvalid(errors)
        }
        return DockExtensionManifest(
            manifestVersion: manifestVersion,
            id: id,
            name: name,
            version: version,
            description: description,
            minCmuxVersion: minCmuxVersion,
            platforms: platforms,
            icon: icon,
            build: build,
            panes: panes,
            unknownTopLevelKeys: unknownTopLevelKeys
        )
    }

    /// Whether `id` is a valid extension id: 1–64 ASCII letters, digits, `.`,
    /// `_`, `:`, `-` (herdr's plugin-id charset), and not dots only (ids name
    /// on-disk directories, so `.`/`..` must never pass).
    public static func isValidExtensionId(_ id: String) -> Bool {
        isValid(id: id, allowDots: true)
    }

    /// Whether `id` is a valid pane id: the extension-id charset minus dots,
    /// so qualified `<extensionId>.<paneId>` ids split unambiguously.
    public static func isValidPaneId(_ id: String) -> Bool {
        isValid(id: id, allowDots: false)
    }

    // MARK: - Field helpers

    private static func isValid(id: String, allowDots: Bool) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        // Ids become on-disk directory names (checkout/config/state/logs).
        // An all-dot id like "." or ".." would resolve to the parent layout
        // directory itself — e.g. uninstall would delete every checkout.
        guard !id.allSatisfy({ $0 == "." }) else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "_", ":", "-":
                return true
            case ".":
                return allowDots
            default:
                return false
            }
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        // Reject booleans (NSNumber bridges true/false) and non-integral numbers.
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double == double.rounded() else { return nil }
        return number.intValue
    }

    private static func requiredString(
        _ object: [String: Any], key: String, maxLength: Int, errors: inout [String]
    ) -> String? {
        guard let value = object[key] else {
            errors.append("\"\(key)\" is required")
            return nil
        }
        return validatedString(value, key: key, maxLength: maxLength, errors: &errors)
    }

    private static func optionalString(
        _ object: [String: Any], key: String, maxLength: Int, errors: inout [String]
    ) -> String? {
        guard let value = object[key] else { return nil }
        return validatedString(value, key: key, maxLength: maxLength, errors: &errors)
    }

    private static func validatedString(
        _ value: Any, key: String, maxLength: Int, errors: inout [String]
    ) -> String? {
        guard let string = value as? String else {
            errors.append("\"\(key)\" must be a string")
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errors.append("\"\(key)\" must not be empty")
            return nil
        }
        guard trimmed.count <= maxLength else {
            errors.append("\"\(key)\" must be at most \(maxLength) characters")
            return nil
        }
        return trimmed
    }

    private static func optionalStringArray(
        _ object: [String: Any], key: String, errors: inout [String]
    ) -> [String]? {
        guard let value = object[key] else { return nil }
        guard let array = value as? [Any] else {
            errors.append("\"\(key)\" must be an array of strings")
            return nil
        }
        var result: [String] = []
        for element in array {
            guard let string = element as? String, !string.isEmpty, string.count <= 32 else {
                errors.append("\"\(key)\" must be an array of non-empty strings (max 32 characters each)")
                return nil
            }
            result.append(string)
        }
        return result
    }

    private static func parseArgv(
        _ value: Any?, context: String, errors: inout [String]
    ) -> [String]? {
        guard let array = value as? [Any] else {
            errors.append("\(context): \"command\" is required and must be an array of strings")
            return nil
        }
        guard !array.isEmpty, array.count <= 64 else {
            errors.append("\(context): \"command\" must have 1–64 elements")
            return nil
        }
        var argv: [String] = []
        for element in array {
            guard let argument = element as? String else {
                errors.append("\(context): \"command\" must contain only strings")
                return nil
            }
            guard argument.count <= 4096 else {
                errors.append("\(context): command arguments must be at most 4096 characters")
                return nil
            }
            argv.append(argument)
        }
        guard let program = argv.first, !program.trimmingCharacters(in: .whitespaces).isEmpty else {
            errors.append("\(context): the first \"command\" element (the program) must not be empty")
            return nil
        }
        return argv
    }

    // MARK: - Sections

    private static func parseBuildSteps(_ value: Any?, errors: inout [String]) -> [DockExtensionBuildStep] {
        guard let value else { return [] }
        guard let array = value as? [Any] else {
            errors.append("\"build\" must be an array of build steps")
            return []
        }
        guard array.count <= 16 else {
            errors.append("\"build\" must have at most 16 steps")
            return []
        }
        var steps: [DockExtensionBuildStep] = []
        for (index, element) in array.enumerated() {
            let context = "build[\(index)]"
            guard let object = element as? [String: Any] else {
                errors.append("\(context): must be an object")
                continue
            }
            let knownKeys: Set<String> = ["command", "platforms"]
            for key in object.keys.sorted() where !knownKeys.contains(key) {
                errors.append("\(context): unknown key \"\(key)\"")
            }
            let command = parseArgv(object["command"], context: context, errors: &errors)
            let platforms = optionalStringArray(object, key: "platforms", errors: &errors)
            if let command {
                steps.append(DockExtensionBuildStep(command: command, platforms: platforms))
            }
        }
        return steps
    }

    private static func parsePanes(_ value: Any?, errors: inout [String]) -> [DockExtensionPane] {
        guard let value else {
            errors.append("\"panes\" is required (at least one pane)")
            return []
        }
        guard let array = value as? [Any], !array.isEmpty else {
            errors.append("\"panes\" must be a non-empty array of panes")
            return []
        }
        guard array.count <= 16 else {
            errors.append("\"panes\" must have at most 16 panes")
            return []
        }
        var panes: [DockExtensionPane] = []
        var seenIds: Set<String> = []
        for (index, element) in array.enumerated() {
            let context = "panes[\(index)]"
            guard let object = element as? [String: Any] else {
                errors.append("\(context): must be an object")
                continue
            }
            let knownKeys: Set<String> = ["id", "title", "command", "env", "cwd", "platforms", "placement"]
            for key in object.keys.sorted() where !knownKeys.contains(key) {
                errors.append("\(context): unknown key \"\(key)\"")
            }

            let id = requiredString(object, key: "id", maxLength: 64, errors: &errors)
            if let id {
                if !isValidPaneId(id) {
                    errors.append("\(context): \"id\" may only contain ASCII letters, digits, '_', ':', '-'")
                } else if !seenIds.insert(id).inserted {
                    errors.append("\(context): duplicate pane id \"\(id)\"")
                }
            }
            let title = requiredString(object, key: "title", maxLength: 100, errors: &errors)
            let command = parseArgv(object["command"], context: context, errors: &errors)
            let env = parseEnv(object["env"], context: context, errors: &errors)
            let cwd = optionalString(object, key: "cwd", maxLength: 512, errors: &errors)
            if let cwd { validateRelativePath(cwd, context: context, errors: &errors) }
            let platforms = optionalStringArray(object, key: "platforms", errors: &errors)
            let placement = optionalString(object, key: "placement", maxLength: 32, errors: &errors)

            if let id, let title, let command {
                panes.append(DockExtensionPane(
                    id: id,
                    title: title,
                    command: command,
                    env: env,
                    cwd: cwd,
                    platforms: platforms,
                    placement: placement
                ))
            }
        }
        return panes
    }

    private static func parseEnv(
        _ value: Any?, context: String, errors: inout [String]
    ) -> [String: String] {
        guard let value else { return [:] }
        guard let object = value as? [String: Any] else {
            errors.append("\(context): \"env\" must be an object of string values")
            return [:]
        }
        guard object.count <= 32 else {
            errors.append("\(context): \"env\" must have at most 32 entries")
            return [:]
        }
        var env: [String: String] = [:]
        for (key, rawValue) in object {
            guard isValidEnvKey(key) else {
                errors.append("\(context): invalid env variable name \"\(key)\"")
                continue
            }
            guard let stringValue = rawValue as? String, stringValue.count <= 4096 else {
                errors.append("\(context): env value for \"\(key)\" must be a string of at most 4096 characters")
                continue
            }
            env[key] = stringValue
        }
        return env
    }

    private static func isValidEnvKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, key.count <= 128 else { return false }
        let isLetter = ("a"..."z").contains(first) || ("A"..."Z").contains(first) || first == "_"
        guard isLetter else { return false }
        return key.unicodeScalars.dropFirst().allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar) || scalar == "_"
        }
    }

    private static func validateRelativePath(
        _ path: String, context: String, errors: inout [String]
    ) {
        if path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") {
            errors.append("\(context): \"cwd\" must be a relative path inside the extension")
            return
        }
        let components = path.split(separator: "/")
        if components.contains("..") {
            errors.append("\(context): \"cwd\" must not contain \"..\"")
        }
    }
}
