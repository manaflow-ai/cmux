public import Foundation

/// A single still-image capture of the shell's composited surface.
public struct ChromiumSurfaceCapture: Sendable {
    /// PNG-encoded pixel data.
    public let pngData: Data
    /// Image width in pixels.
    public let width: UInt32
    /// Image height in pixels.
    public let height: UInt32

    /// Decodes a capture from the JSON produced by
    /// `owl_fresh_mojo_surface_tree_capture_surface_json`.
    ///
    /// - Throws: ``ChromiumRuntimeError/callFailed(_:)`` if the runtime reported
    ///   a non-empty `error` field, or a decoding error if the JSON is malformed.
    public init(json: String) throws {
        let wire = try JSONDecoder().decode(Wire.self, from: Data(json.utf8))
        guard wire.error.isEmpty else {
            throw ChromiumRuntimeError.callFailed(wire.error)
        }
        guard let data = Data(base64Encoded: wire.pngBase64) else {
            throw ChromiumRuntimeError.callFailed("capture pngBase64 was not valid base64")
        }
        self.pngData = data
        self.width = wire.width
        self.height = wire.height
    }

    private struct Wire: Decodable {
        let pngBase64: String
        let width: UInt32
        let height: UInt32
        let error: String
    }
}
