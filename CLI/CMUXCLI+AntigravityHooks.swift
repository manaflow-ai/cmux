import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Antigravity hooks
extension CMUXCLI {
    private static let antigravityHookGroupName = "cmux"

    func installAntigravityHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")

        let configDirectoryFileError = String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.error.configDirectoryIsFile",
                defaultValue: "cmux could not create the hooks directory: a file exists at %@; remove or rename the conflicting file and re-run `cmux hooks setup`"
            ),
            configDir
        )
        var isConfigDirectory = ObjCBool(false)
        let configPathExists = fm.fileExists(atPath: configDir, isDirectory: &isConfigDirectory)
        if configPathExists, !isConfigDirectory.boolValue {
            throw CLIError(message: configDirectoryFileError)
        }
        if !configPathExists {
            do {
                try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            } catch {
                throw CLIError(message: configDirectoryFileError)
            }
        }

        var existing: [String: Any] = [:]
        if let data = fm.contents(atPath: filePath) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(
                        localized: "cli.hooks.antigravity.error.invalidJSON",
                        defaultValue: "%@ exists but is not valid JSON. Fix or remove it before installing hooks."
                    ),
                    filePath
                ))
            }
            existing = json
        }

        let newGroup = buildHooksDict(for: def)
        existing[Self.antigravityHookGroupName] = newGroup

        let newData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys])
        let newString = String(data: newData, encoding: .utf8) ?? "{}"
        let oldString: String = {
            guard let data = fm.contents(atPath: filePath),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
                  let string = String(data: pretty, encoding: .utf8) else {
                return ""
            }
            return string
        }()

        if oldString == newString {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.antigravity.alreadyUpToDate",
                    defaultValue: "%@ hooks already up to date at %@"
                ),
                def.displayName,
                filePath
            ))
            return
        }
        if !skipConfirm {
            Self.printInstallPreview(
                path: filePath,
                oldContent: oldString,
                newContent: newString,
                fallbackContent: newString
            )
            print(String(
                localized: "cli.hooks.antigravity.confirmProceed",
                defaultValue: "\nProceed? [y/N] "
            ), terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print(String(
                    localized: "cli.hooks.antigravity.aborted",
                    defaultValue: "Aborted."
                ))
                return
            }
        }
        try newData.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.antigravity.installed",
                defaultValue: "%@ hooks installed at %@"
            ),
            def.displayName,
            filePath
        ))
    }

    func uninstallAntigravityHooks(_ def: AgentHookDef) throws {
        let filePath = "\(def.resolvedConfigDir())/\(def.configFile)"
        let fm = FileManager.default
        guard let data = fm.contents(atPath: filePath) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.antigravity.noneFound",
                    defaultValue: "No %@ found at %@"
                ),
                def.configFile,
                filePath
            ))
            return
        }
        let jsonObject: Any?
        let malformedJSON: Bool
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
            malformedJSON = false
        } catch {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.antigravity.malformedJSON",
                    defaultValue: "Malformed %@ at %@. Fix or remove it before uninstalling hooks."
                ),
                def.configFile,
                filePath
            ))
            jsonObject = nil
            malformedJSON = true
        }
        var json = jsonObject as? [String: Any] ?? [:]

        guard let group = json[Self.antigravityHookGroupName],
              Self.jsonHookValueContainsCmuxOwnedCommand(group, for: def) else {
            if !malformedJSON {
                print(String.localizedStringWithFormat(
                    String(
                        localized: "cli.hooks.antigravity.removedZero",
                        defaultValue: "Removed 0 cmux hook(s) from %@"
                    ),
                    filePath
                ))
            }
            return
        }

        json.removeValue(forKey: Self.antigravityHookGroupName)
        let newData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.antigravity.removed",
                defaultValue: "Removed Antigravity cmux hooks from %@"
            ),
            filePath
        ))
    }

    private static func jsonHookValueContainsCmuxOwnedCommand(_ value: Any, for def: AgentHookDef) -> Bool {
        if let command = value as? String {
            return isCmuxOwnedHookCommand(command, for: def)
        }
        if let array = value as? [Any] {
            return array.contains { jsonHookValueContainsCmuxOwnedCommand($0, for: def) }
        }
        if let object = value as? [String: Any] {
            if let command = object["command"] as? String,
               isCmuxOwnedHookCommand(command, for: def) {
                return true
            }
            return object.values.contains { jsonHookValueContainsCmuxOwnedCommand($0, for: def) }
        }
        return false
    }

}
