// SPDX-License-Identifier: MIT

/// A single screen-read request, addressable by ``SurfaceHandle`` and
/// parameterised by format/region/wrap/trim. Consumed by
/// ``TerminalAccessService/readScreen(_:)``.
public struct ScreenReadRequest: Hashable, Sendable, Codable {
    /// The surface to read from.
    public let handle: SurfaceHandle
    /// Output format requested by the caller.
    public let format: ScreenFormat
    /// Region of the surface to read.
    public let region: ScreenRegion
    /// How to render soft-wrapped (DECAWM) lines when emitting text.
    public let wrap: WrapPolicy
    /// Whether trailing whitespace/blank lines should be trimmed from
    /// the result.
    public let trim: Bool

    /// Creates a new read request. All non-handle parameters carry safe
    /// Phase 0 defaults (``ScreenFormat/text`` /
    /// ``ScreenRegion/viewport`` / ``WrapPolicy/preserve`` / `trim: true`).
    public init(
        handle: SurfaceHandle,
        format: ScreenFormat = .text,
        region: ScreenRegion = .viewport,
        wrap: WrapPolicy = .preserve,
        trim: Bool = true
    ) {
        self.handle = handle
        self.format = format
        self.region = region
        self.wrap = wrap
        self.trim = trim
    }
}
