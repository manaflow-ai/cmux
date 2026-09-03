import Foundation

/// Validates a sidebar extension manifest before CMUX trusts it.
@_spi(CmuxHostTransport)
public func validateSidebarManifest(
    _ manifest: CmuxExtensionManifest,
    supportedAPIVersion: CmuxExtensionAPIVersion = .sidebarV2
) throws {
    guard manifest.kind == .sidebar else {
        throw CmuxExtensionValidationError.invalidDeclaration(
            kind: "manifest",
            identifier: manifest.id,
            reason: "sidebar manifests must declare kind=sidebar"
        )
    }
    guard manifest.pluginScopes.isEmpty,
          manifest.eventSubscriptions.isEmpty,
          manifest.actions.isEmpty,
          manifest.entrypoint == nil else {
        throw CmuxExtensionValidationError.invalidDeclaration(
            kind: "manifest",
            identifier: manifest.id,
            reason: "sidebar manifests cannot declare process-backed plugin capabilities"
        )
    }
    guard manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw CmuxExtensionValidationError.emptyIdentifier
    }
    guard manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw CmuxExtensionValidationError.emptyDisplayName
    }
    guard manifest.minimumAPIVersion.major == supportedAPIVersion.major,
          manifest.minimumAPIVersion <= supportedAPIVersion else {
        throw CmuxExtensionValidationError.unsupportedAPIVersion(
            requested: manifest.minimumAPIVersion,
            supported: supportedAPIVersion
        )
    }
}

/// Validates a process-backed plugin manifest before it is enabled.
///
/// Validation is deliberately strict and side-effect free. Unknown JSON enum
/// values fail during decoding, identifiers are constrained to a safe command
/// and directory namespace, and every declared action/event must be unique.
/// The permission store still defaults to no access after validation; passing
/// this function never implies user approval.
@_spi(CmuxHostTransport)
public func validatePluginManifest(
    _ manifest: CmuxExtensionManifest,
    supportedAPIVersion: CmuxExtensionAPIVersion = .pluginV3
) throws {
    try CmuxPluginManifestValidation.validateCommonManifestFields(manifest)

    guard manifest.kind == .plugin else {
        throw CmuxExtensionValidationError.invalidDeclaration(
            kind: "manifest",
            identifier: manifest.id,
            reason: "plugin manifests must declare kind=plugin"
        )
    }
    guard manifest.minimumAPIVersion.major >= 0,
          manifest.minimumAPIVersion.minor >= 0 else {
        throw CmuxExtensionValidationError.invalidDeclaration(
            kind: "api",
            identifier: manifest.id,
            reason: "minimumAPIVersion components must be non-negative"
        )
    }
    guard manifest.minimumAPIVersion.isCompatible(with: supportedAPIVersion) else {
        throw CmuxExtensionValidationError.unsupportedPluginAPIVersion(
            requested: manifest.minimumAPIVersion,
            supported: supportedAPIVersion
        )
    }

    let trimmedIdentifier = manifest.id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedIdentifier == manifest.id else {
        throw CmuxExtensionValidationError.invalidIdentifier(manifest.id)
    }
    guard manifest.displayName.count <= 256,
          !CmuxPluginManifestValidation.containsControlCharacters(manifest.displayName) else {
        throw CmuxExtensionValidationError.invalidDeclaration(
            kind: "manifest",
            identifier: manifest.id,
            reason: "displayName must be at most 256 characters and contain no control characters"
        )
    }
    guard manifest.pluginScopes.count <= 16,
          manifest.eventSubscriptions.count <= 128,
          manifest.actions.count <= 128 else {
        throw CmuxExtensionValidationError.invalidDeclaration(
            kind: "manifest",
            identifier: manifest.id,
            reason: "plugin declarations exceed the supported count limit"
        )
    }

    // The first process-backed slice intentionally exposes only the event and
    // palette transports. Keeping the future UI scopes in the vocabulary but
    // rejecting them here makes the capability boundary explicit and
    // fail-closed until their host plumbing is shipped.
    for scope in manifest.pluginScopes where scope == .paneContent || scope == .workspaceBadges {
        throw CmuxExtensionValidationError.unsupportedPluginScope(scope)
    }

    guard manifest.entrypoint != nil else {
        throw CmuxExtensionValidationError.missingEntrypointDeclaration
    }

    guard manifest.readScopes.isEmpty, manifest.actionScopes.isEmpty else {
        throw CmuxExtensionValidationError.invalidDeclaration(
            kind: "manifest",
            identifier: manifest.id,
            reason: "process-backed plugins cannot declare sidebar-only read or action scopes"
        )
    }

    if !manifest.eventSubscriptions.isEmpty,
       !manifest.pluginScopes.contains(.eventHooks) {
        throw CmuxExtensionValidationError.invalidDeclaration(
            kind: "scope",
            identifier: manifest.id,
            reason: "eventSubscriptions require the eventHooks plugin scope"
        )
    }
    if !manifest.actions.isEmpty,
       !manifest.pluginScopes.contains(.paletteActions) {
        throw CmuxExtensionValidationError.invalidDeclaration(
            kind: "scope",
            identifier: manifest.id,
            reason: "actions require the paletteActions plugin scope"
        )
    }

    guard Set(manifest.pluginScopes).count == manifest.pluginScopes.count else {
        throw CmuxExtensionValidationError.invalidDeclaration(
            kind: "scope",
            identifier: manifest.id,
            reason: "pluginScopes must not contain duplicates"
        )
    }

    var seenEvents = Set<String>()
    for event in manifest.eventSubscriptions {
        guard seenEvents.insert(event.rawValue).inserted else {
            throw CmuxExtensionValidationError.duplicateDeclaration(
                kind: "event",
                identifier: event.rawValue
            )
        }
    }

    var seenActions = Set<String>()
    for action in manifest.actions {
        let actionID = action.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard actionID == action.id else {
            throw CmuxExtensionValidationError.invalidDeclaration(
                kind: "action",
                identifier: action.id,
                reason: "action ids must not contain leading or trailing whitespace"
            )
        }
        guard CmuxPluginManifestValidation.isSafeComponent(actionID, maximumLength: 96) else {
            throw CmuxExtensionValidationError.invalidDeclaration(
                kind: "action",
                identifier: action.id,
                reason: "action ids must be non-empty and contain only letters, digits, '.', '_' or '-'"
            )
        }
        guard !action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CmuxExtensionValidationError.invalidDeclaration(
                kind: "action",
                identifier: action.id,
                reason: "action titles must not be blank"
            )
        }
        guard action.title.count <= 256,
              !CmuxPluginManifestValidation.containsControlCharacters(action.title) else {
            throw CmuxExtensionValidationError.invalidDeclaration(
                kind: "action",
                identifier: action.id,
                reason: "action titles must be at most 256 characters and contain no control characters"
            )
        }
        if let subtitle = action.subtitle {
            guard !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  subtitle.count <= 256,
                  !CmuxPluginManifestValidation.containsControlCharacters(subtitle) else {
                throw CmuxExtensionValidationError.invalidDeclaration(
                    kind: "action",
                    identifier: actionID,
                    reason: "action subtitles must be non-blank, at most 256 characters, and contain no control characters"
                )
            }
        }
        guard action.keywords.count <= 64,
              action.keywords.allSatisfy({
                  $0.count <= 128 && !CmuxPluginManifestValidation.containsControlCharacters($0)
              }) else {
            throw CmuxExtensionValidationError.invalidDeclaration(
                kind: "action",
                identifier: action.id,
                reason: "action keywords exceed the supported count or length limit"
            )
        }
        guard seenActions.insert(actionID).inserted else {
            throw CmuxExtensionValidationError.duplicateDeclaration(
                kind: "action",
                identifier: actionID
            )
        }
        if let defaultShortcut = action.defaultShortcut,
           defaultShortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CmuxExtensionValidationError.invalidDeclaration(
                kind: "action",
                identifier: actionID,
                reason: "defaultShortcut must not be blank"
            )
        }
        if let defaultShortcut = action.defaultShortcut,
           defaultShortcut.count > 128 || CmuxPluginManifestValidation.containsControlCharacters(defaultShortcut) {
            throw CmuxExtensionValidationError.invalidDeclaration(
                kind: "action",
                identifier: actionID,
                reason: "defaultShortcut is too long or contains control characters"
            )
        }
        if let defaultShortcut = action.defaultShortcut,
           !CmuxPluginManifestValidation.isValidShortcutDeclaration(defaultShortcut) {
            throw CmuxExtensionValidationError.invalidDeclaration(
                kind: "action",
                identifier: actionID,
                reason: "defaultShortcut must contain one or two valid strokes; the first stroke must be modifier-qualified"
            )
        }
    }

    if let entrypoint = manifest.entrypoint {
        guard CmuxPluginManifestValidation.isRelativeEntrypoint(entrypoint) else {
            throw CmuxExtensionValidationError.invalidEntrypoint(entrypoint)
        }
    }
}

private enum CmuxPluginManifestValidation {
    static func validateCommonManifestFields(_ manifest: CmuxExtensionManifest) throws {
        let identifier = manifest.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            throw CmuxExtensionValidationError.emptyIdentifier
        }
        guard isSafeComponent(identifier, maximumLength: 128) else {
            throw CmuxExtensionValidationError.invalidIdentifier(manifest.id)
        }
        guard !manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CmuxExtensionValidationError.emptyDisplayName
        }
    }

    static func isSafeComponent(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let isLetter = (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            return isLetter || isDigit || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            guard !CharacterSet.controlCharacters.contains(scalar) else { return true }
            let value = scalar.value
            // Format and bidi controls are not Cc characters, but they can
            // reorder or hide user-visible manifest text. Reject them at the
            // package boundary so every host consumer gets the same policy.
            return value == 0x00AD
                || (0x0600...0x0605).contains(value)
                || value == 0x061C
                || (0x200B...0x200F).contains(value)
                || (0x202A...0x202E).contains(value)
                || (0x2060...0x2064).contains(value)
                || (0x2066...0x2069).contains(value)
                || (0xFFF9...0xFFFB).contains(value)
                || value == 0xFEFF
        }
    }

    static func isRelativeEntrypoint(_ value: String) -> Bool {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              !components.contains("."),
              !components.contains(".."),
              !components.contains("") else { return false }
        return components.allSatisfy { component in
            isSafeComponent(String(component), maximumLength: 128)
        }
    }

    static func isValidShortcutDeclaration(_ value: String) -> Bool {
        let strokes = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard (1...2).contains(strokes.count) else { return false }
        for (index, stroke) in strokes.enumerated() {
            let parts = stroke.split(separator: "+", omittingEmptySubsequences: false)
            guard let key = parts.last,
                  !key.isEmpty,
                  !isShortcutModifier(key) else { return false }
            let modifiers = parts.dropLast()
            guard modifiers.allSatisfy(isShortcutModifier) else { return false }
            // A chord's first stroke must own a modifier; the second stroke
            // may be a bare key (tmux-style `ctrl+b c`).
            guard index > 0 || !modifiers.isEmpty else { return false }
        }
        return true
    }

    private static func isShortcutModifier(_ value: Substring) -> Bool {
        switch value.lowercased() {
        case "cmd", "command", "⌘", "shift", "⇧", "opt", "option", "alt", "⌥",
             "ctrl", "control", "ctl", "⌃":
            return true
        default:
            return false
        }
    }
}
