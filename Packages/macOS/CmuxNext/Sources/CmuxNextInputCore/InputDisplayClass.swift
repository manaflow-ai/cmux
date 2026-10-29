/// The display a batch of inputs was presented on, as a row label: its highest refresh rate and
/// whether the rate varies (ProMotion, adaptive sync: the minimum and maximum refresh differ).
/// Estimated presentation times on a variable-rate display are less exact, so
/// rows are kept apart per display and labelled (p04-input.md, DC12 "VRR rows labelled").
public struct InputDisplayClass: Sendable, Hashable, Codable {
    /// The highest refresh rate, in whole hertz (0 when unknown).
    public var refreshHz: Int
    /// Whether the refresh rate varies.
    public var vrr: Bool

    /// No display known (the batch's producer did not say).
    public static let unknown = InputDisplayClass(refreshHz: 0, vrr: false)

    public init(refreshHz: Int, vrr: Bool) {
        self.refreshHz = refreshHz
        self.vrr = vrr
    }

    private enum CodingKeys: String, CodingKey {
        case refreshHz = "refresh_hz"
        case vrr
    }
}
