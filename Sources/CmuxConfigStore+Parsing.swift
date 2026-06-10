import Bonsplit
import CmuxFileWatch
import Combine
import CryptoKit
import Foundation


// MARK: - Config Parsing & Schema Diagnostics
extension CmuxConfigStore {
    func sanitizeConfigText(_ text: String) -> String {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{FEFF}",
        ]
        let filtered = String(text.unicodeScalars.filter { !dangerous.contains($0) })
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func sanitizeConfigText(_ text: String, fallback: String) -> String {
        let sanitized = sanitizeConfigText(text)
        return sanitized.isEmpty ? fallback : sanitized
    }

    func parseConfig(at path: String) -> ParsedConfigResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            parsedConfigCache.removeValue(forKey: path)
            return ParsedConfigResult(config: nil, issue: nil)
        }

        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationDate = attributes?[.modificationDate] as? Date
        let paletteFingerprint = WorkspaceTabColorSettings.paletteCacheFingerprint()

        if let cached = parsedConfigCache[path],
           cached.fileSize == fileSize,
           cached.modificationDate == modificationDate,
           cached.workspaceColorPaletteFingerprint == paletteFingerprint {
            return ParsedConfigResult(config: cached.config, issue: cached.issue)
        }

        guard let data = fileManager.contents(atPath: path),
              !data.isEmpty else {
            let issue = schemaIssue(path: path, message: "cmux.json is empty")
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                config: nil,
                issue: issue
            )
            return ParsedConfigResult(config: nil, issue: issue)
        }
        let sanitized: Data
        do {
            sanitized = try JSONCParser.preprocess(data: data)
        } catch {
            let issue = schemaIssue(path: path, message: "JSONC preprocessing failed: \(schemaErrorMessage(error))")
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                config: nil,
                issue: issue
            )
            NSLog("[CmuxConfig] JSONC preprocessing error at %@: %@", path, String(describing: error))
            return ParsedConfigResult(config: nil, issue: issue)
        }

        do {
            let config = try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                config: config,
                issue: nil
            )
            return ParsedConfigResult(config: config, issue: nil)
        } catch {
            let issue = schemaIssue(path: path, message: schemaErrorMessage(error))
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                config: nil,
                issue: issue
            )
            NSLog("[CmuxConfig] parse error at %@: %@", path, String(describing: error))
            return ParsedConfigResult(config: nil, issue: issue)
        }
    }

    private func schemaIssue(path: String, message: String) -> CmuxConfigIssue {
        CmuxConfigIssue(
            kind: .schemaError,
            settingName: (path as NSString).lastPathComponent,
            sourcePath: path,
            message: message
        )
    }

    private func schemaErrorMessage(_ error: Error) -> String {
        switch error {
        case DecodingError.typeMismatch(_, let context):
            return schemaErrorMessage(context)
        case DecodingError.valueNotFound(_, let context):
            return schemaErrorMessage(context)
        case DecodingError.keyNotFound(let key, let context):
            let path = schemaCodingPath(context.codingPath + [key])
            let detail = sanitizeConfigText(context.debugDescription)
            return "\(path): \(detail)"
        case DecodingError.dataCorrupted(let context):
            return schemaErrorMessage(context)
        default:
            let message = sanitizeConfigText(error.localizedDescription)
            return message.isEmpty ? String(describing: error) : message
        }
    }

    private func schemaErrorMessage(_ context: DecodingError.Context) -> String {
        let path = schemaCodingPath(context.codingPath)
        let detail = sanitizeConfigText(context.debugDescription)
        return detail.isEmpty ? path : "\(path): \(detail)"
    }

    private func schemaCodingPath(_ codingPath: [CodingKey]) -> String {
        let path = codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
        return path.isEmpty ? "root" : path
    }

    // MARK: - File watching (local)

}
