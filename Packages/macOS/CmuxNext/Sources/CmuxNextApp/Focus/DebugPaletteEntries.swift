#if DEBUG
import CmuxNextControl
import CmuxNextPalette
import CmuxNextSettings
import Foundation

/// `debug.palette.entries {scope?, path}` (DEBUG builds): writes a scope's
/// ranker input to `path`, the palette-ranking eval fixture
/// (plans/cmux-next/palette-ranking.md, webviews/test/fixtures/palette-eval).
enum DebugPaletteEntries {
    @MainActor
    static func write(_ params: [String: JSONValue], services: AppServices?) async throws -> JSONValue {
        guard let path = params["path"]?.stringValue, !path.isEmpty else { throw ControlError.invalidParams("path is required") }
        let scope = PaletteScopeID(params["scope"]?.stringValue ?? PaletteScopeID.root.rawValue)
        guard let palette = services?.palette, let data = await palette.rankFixture(scope: scope) else {
            throw ControlError.invalidParams("unknown scope \(scope.rawValue)")
        }
        try data.write(to: URL(fileURLWithPath: path))
        return .object(["path": .string(path), "bytes": .number(Double(data.count))])
    }
}
#endif
