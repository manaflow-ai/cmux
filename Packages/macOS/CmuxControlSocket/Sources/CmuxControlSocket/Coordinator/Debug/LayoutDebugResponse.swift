public import Bonsplit
import Foundation

/// The JSON payload the `layout_debug` command returns: the active tab's
/// Bonsplit ``LayoutSnapshot`` plus each selected panel's resolved layout state
/// and the current main/key window numbers.
///
/// The app-side witness performs the AppKit walk (split-view geometry, panel
/// resolution) and builds the ``LayoutDebugSelectedPanel`` array; this value
/// type owns the wire shape and the `OK <json>` line assembly so the god file
/// keeps only the live state reads. The declared property order is the wire
/// order: synthesized `Codable` encodes in declaration order, so the emitted
/// JSON is byte-identical to the legacy app-side struct.
public struct LayoutDebugResponse: Codable, Sendable {
    /// The active tab's layout snapshot.
    public let layout: LayoutSnapshot
    /// The active tab's selected panels, one per pane.
    public let selectedPanels: [LayoutDebugSelectedPanel]
    /// The app's main window number, when there is one.
    public let mainWindowNumber: Int?
    /// The app's key window number, when there is one.
    public let keyWindowNumber: Int?

    /// Creates a layout-debug payload from already-read layout state.
    ///
    /// - Parameters:
    ///   - layout: The active tab's layout snapshot.
    ///   - selectedPanels: The active tab's selected panels, one per pane.
    ///   - mainWindowNumber: The app's main window number, when there is one.
    ///   - keyWindowNumber: The app's key window number, when there is one.
    public init(
        layout: LayoutSnapshot,
        selectedPanels: [LayoutDebugSelectedPanel],
        mainWindowNumber: Int?,
        keyWindowNumber: Int?
    ) {
        self.layout = layout
        self.selectedPanels = selectedPanels
        self.mainWindowNumber = mainWindowNumber
        self.keyWindowNumber = keyWindowNumber
    }

    /// Encodes the payload as the `layout_debug` `OK <json>` response line, or
    /// `nil` when JSON encoding fails (the legacy
    /// `ERROR: Failed to encode layout_debug` outcome the caller forms).
    public func okResponseLine() -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return "OK \(json)"
    }
}
