import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The Settings page's Save as Ghostty Theme and Import Theme File (cx-wqn5.1), through
/// `GhosttyThemeFiles`: the file is written off the main thread, then the theme catalog reloads, so
/// the page's next theme list has it. Both write the person's Ghostty themes folder, so only the
/// person may call them (not an agent driving the page).
///
/// - `cmux.settings.theme.save` `{name, base, replace?}` writes `base` with its saved
///   `appearance.themeEdits` as the theme `name`; returns `{name}`.
/// - `cmux.settings.theme.import` `{token?, replace?}` asks for a file in the cmux picker and copies
///   its colors in; returns `{name}`, or `{}` when the person left the picker. A name in use answers
///   `cmux.settings.theme.exists` with a `token`; the call again with that token and `replace` replaces
///   it without asking for the file again.
@MainActor
final class SettingsThemeFiles {
    struct Folders: Sendable {
        var resources: String?
        var home: URL
        var environment: [String: String]
    }

    private let folders: @MainActor () -> Folders
    private let reload: @MainActor () async -> Void
    private let pickFile: @MainActor () async -> URL?
    /// Files picked for an import whose name was in use, by token, until the retry.
    private var pending: [String: URL] = [:]

    init(folders: @escaping @MainActor () -> Folders, reload: @escaping @MainActor () async -> Void,
         pickFile: @escaping @MainActor () async -> URL?) {
        self.folders = folders
        self.reload = reload
        self.pickFile = pickFile
    }

    func call(_ op: String, params: JSONValue, edits: ThemeEdits, writer: SettingWriter) async throws -> JSONValue {
        guard writer == .user else {
            throw PageError(code: "cmux.settings.user_only", message: "only the person saves or imports a theme file")
        }
        let folders = folders()
        let replace = params["replace"]?.boolValue ?? false
        let name: String
        if op == "cmux.settings.theme.save" {
            guard let target = params["name"]?.stringValue, let base = params["base"]?.stringValue else {
                throw PageError.invalidParams("name and base are required")
            }
            let colors = edits.colors[base] ?? [:]
            _ = try await Self.run {
                try GhosttyThemeFiles.save(name: target, base: base, edits: colors, resources: folders.resources,
                                           home: folders.home, environment: folders.environment, replace: replace)
            }
            name = target
        } else {
            let token = params["token"]?.stringValue
            // A new pick drops the files of imports the person did not retry.
            if token == nil { pending.removeAll() }
            let picked = token.flatMap { pending.removeValue(forKey: $0) }
            guard let file = token == nil ? await pickFile() : picked else {
                if token != nil { throw PageError.invalidParams("unknown import token") }
                return .object([:])
            }
            do {
                name = try await Self.run {
                    try GhosttyThemeFiles.importTheme(at: file, resources: folders.resources, home: folders.home,
                                                      environment: folders.environment, replace: replace)
                }
            } catch let error as PageError where error.code == Self.code(.exists) {
                let retry = UUID().uuidString
                pending[retry] = file
                throw Self.error(.exists, details: ["token": .string(retry), "name": .string(Self.importName(file))])
            }
        }
        await reload()
        return ["name": .string(name)]
    }

    /// Runs file work off the main thread and turns a refusal into the page's error.
    private static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        do {
            return try await Task.detached(priority: .userInitiated) { try work() }.value
        } catch let refusal as GhosttyThemeFiles.Refusal {
            throw error(refusal)
        }
    }

    private static func error(_ refusal: GhosttyThemeFiles.Refusal, details: JSONValue? = nil) -> PageError {
        let message = switch refusal {
        case .invalidName: "not a theme name"
        case .shippedName: "a theme that ships with cmux has this name"
        case .exists: "a theme with this name exists"
        case .unknownBase: "the theme has no file"
        case .notATheme: "the file sets no theme colors"
        }
        return PageError(code: code(refusal), message: message, details: details)
    }

    private static func code(_ refusal: GhosttyThemeFiles.Refusal) -> String {
        let suffix = switch refusal {
        case .invalidName: "invalid_name"
        case .shippedName: "shipped_name"
        case .exists: "exists"
        case .unknownBase: "unknown_base"
        case .notATheme: "not_a_theme"
        }
        return "cmux.settings.theme.\(suffix)"
    }

    private static func importName(_ file: URL) -> String {
        ["conf", "theme"].contains(file.pathExtension.lowercased()) ? file.deletingPathExtension().lastPathComponent : file.lastPathComponent
    }
}
