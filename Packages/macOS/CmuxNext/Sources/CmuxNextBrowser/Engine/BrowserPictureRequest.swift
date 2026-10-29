public import CoreGraphics

/// A page picture already asked of its engine (``BrowserTab/beginThumbnail()``): ``image()`` awaits the answer.
@MainActor
public struct BrowserPictureRequest: Sendable {
    private let answer: @MainActor @Sendable () async throws -> CGImage

    /// - Parameter answer: Awaits the engine's answer; runs at most once per ``image()``.
    public init(_ answer: @escaping @MainActor @Sendable () async throws -> CGImage) {
        self.answer = answer
    }

    /// A request the engine refused when it was asked: ``image()`` throws `error`.
    public static func refused(_ error: BrowserTabError) -> BrowserPictureRequest {
        BrowserPictureRequest { throw error }
    }

    /// The picture, or the engine's error.
    public func image() async throws -> CGImage { try await answer() }
}
