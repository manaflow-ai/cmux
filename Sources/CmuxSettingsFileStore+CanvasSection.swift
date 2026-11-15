import CmuxSettings
import Foundation

extension CmuxSettingsFileStore {
    /// `canvas.*`: the pane gap and edge snapping of the freeform canvas layout.
    func parseCanvasSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        let canvas = CanvasCatalogSection()
        // The gap is a whole number of points. Check the range on the JSON
        // number before converting: `Int(1e100)` traps, and a truncated
        // oversized value could land inside the accepted range.
        if let value = jsonDouble(section["paneGap"]),
           CanvasLayoutSettings.paneGapRange.contains(value),
           value.rounded() == value {
            snapshot.managedUserDefaults[canvas.paneGap.userDefaultsKey] = .int(Int(value))
        } else if section.keys.contains("paneGap") {
            logInvalid(canvas.paneGap.id, sourcePath: sourcePath)
        }
        if let value = jsonBool(section["snappingEnabled"]) {
            snapshot.managedUserDefaults[canvas.snappingEnabled.userDefaultsKey] = .bool(value)
        } else if section.keys.contains("snappingEnabled") {
            logInvalid(canvas.snappingEnabled.id, sourcePath: sourcePath)
        }
    }
}
