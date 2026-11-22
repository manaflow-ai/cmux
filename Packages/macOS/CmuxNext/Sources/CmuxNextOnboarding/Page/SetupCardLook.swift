public import CmuxNextSettings

/// The Set Up cmux card's Text Size and Density row (David Beyer, 2026-11-20: Settings was overwhelming and he could
/// not find a sidebar font size): what the app draws now, and the one writer the person's pick goes through. The App
/// gives it the design settings' reads and `SettingsController.setSetting`, so the card writes exactly what
/// Settings > General's Text Size card writes (webviews ui/TextSizePicker draws both).
@MainActor
public struct SetupCardLook {
    /// What the app draws now.
    public struct Current: Sendable, Equatable {
        /// `appearance.metrics.chromeFontSize` in points, or nil (the density's own size).
        public var textSize: Double?
        /// The density's id: `appearance.density`, or a custom density's id.
        public var density: String
        /// The density's chrome body text in points (`DensityTokens.bodySize`).
        public var body: Double

        public init(textSize: Double?, density: String, body: Double) {
            self.textSize = textSize
            self.density = density
            self.body = body
        }
    }

    /// Reads what the app draws now; called inside observation, so an observable source wakes the card.
    public var current: @MainActor () -> Current
    /// Writes one setting (`path`, or nil to remove it) as the person's own change.
    public var write: @MainActor (_ path: [String], _ value: JSONValue?) async throws -> Void

    public init(current: @escaping @MainActor () -> Current,
                write: @escaping @MainActor (_ path: [String], _ value: JSONValue?) async throws -> Void) {
        self.current = current
        self.write = write
    }

    /// The row on the wire (setupModel.ts `SetupState.look`).
    var wire: JSONValue {
        let now = current()
        return ["textSize": now.textSize.map(JSONValue.number) ?? .null, "density": .string(now.density), "body": .number(now.body)]
    }
}
