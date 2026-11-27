import Foundation

/// A window's Chief panel in its record (`WindowRecord.chiefPanel`): whether it is open, floating or docked, and its
/// places. Opaque to the daemon, like the rest of the record. Every field has a default, so a partial or older
/// record reads as a closed floating panel.
public struct WindowChiefPanelRecord: Codable, Sendable, Hashable {
    /// The panel is open (it still draws nothing while the window shows Home).
    public var open: Bool
    /// `floating`, or the docked edge: `left`, `right`, `top` or `bottom`. A client floats a value it does not know.
    public var placement: String
    /// The floating place as fractions of the content area (y runs down): x, y, width, height.
    public var frame: [Double]
    /// The docked width or height, permille of the content area.
    public var extentPermille: Int

    /// - Parameters:
    ///   - open: Whether the panel is open.
    ///   - placement: `floating` or a docked edge.
    ///   - frame: x, y, width, height as fractions of the content area.
    ///   - extentPermille: The docked extent, permille.
    public init(open: Bool, placement: String, frame: [Double], extentPermille: Int) {
        self.open = open
        self.placement = placement
        self.frame = frame
        self.extentPermille = extentPermille
    }

    enum CodingKeys: String, CodingKey {
        case open, placement, frame
        case extentPermille = "extent_permille"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        open = try c.decodeIfPresent(Bool.self, forKey: .open) ?? false
        placement = try c.decodeIfPresent(String.self, forKey: .placement) ?? "floating"
        frame = try c.decodeIfPresent([Double].self, forKey: .frame) ?? []
        extentPermille = try c.decodeIfPresent(Int.self, forKey: .extentPermille) ?? 300
    }
}
