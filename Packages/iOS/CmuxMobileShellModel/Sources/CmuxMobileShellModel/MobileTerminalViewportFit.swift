import Foundation

/// The negotiated terminal viewport: the effective grid the remote will render,
/// the optional client-requested grid, and whether the current client is the
/// limiting factor.
///
/// Decodes/encodes with the wire convention the mac side speaks: `effective`,
/// `client`, and `is_current_client_limiting`. The `shouldDrawVisibleArea*`
/// helpers drive the visible-area border overlay in the terminal UI.
public struct MobileTerminalViewportFit: Codable, Equatable, Sendable {
    /// The grid size the remote will actually render.
    public var effective: MobileTerminalViewportSize
    /// The grid size this client requested, when known.
    public var client: MobileTerminalViewportSize?
    /// Whether this client is the dimension currently constraining the fit.
    public var isCurrentClientLimiting: Bool

    /// Creates a viewport fit.
    /// - Parameters:
    ///   - effective: The grid size the remote will render.
    ///   - client: The grid size this client requested, if known.
    ///   - isCurrentClientLimiting: Whether this client is the limiting dimension.
    public init(
        effective: MobileTerminalViewportSize,
        client: MobileTerminalViewportSize?,
        isCurrentClientLimiting: Bool
    ) {
        self.effective = effective
        self.client = client
        self.isCurrentClientLimiting = isCurrentClientLimiting
    }

    /// Whether either visible-area border (right or bottom) should be drawn.
    public var shouldDrawVisibleAreaBorder: Bool {
        shouldDrawVisibleAreaRightBorder || shouldDrawVisibleAreaBottomBorder
    }

    /// Whether the right visible-area border should be drawn because the client
    /// requested more columns than the effective grid provides.
    public var shouldDrawVisibleAreaRightBorder: Bool {
        guard let client else { return false }
        return client.columns > effective.columns
    }

    /// Whether the bottom visible-area border should be drawn because the client
    /// requested more rows than the effective grid provides.
    public var shouldDrawVisibleAreaBottomBorder: Bool {
        guard let client else { return false }
        return client.rows > effective.rows
    }

    private enum CodingKeys: String, CodingKey {
        case effective
        case client
        case isCurrentClientLimiting = "is_current_client_limiting"
    }
}
