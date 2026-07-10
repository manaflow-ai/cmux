@preconcurrency import AVFoundation
import CmuxSimulator
import CoreImage
import Foundation
import ImageIO

public struct SimulatorCameraSourceClassifier: Sendable {
    public init() {}

    public func configuration(for url: URL) async -> SimulatorCameraConfiguration? {
        let isImage = await Task.detached {
            Self.isImage(url)
        }.value
        if isImage { return .image(url) }

        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              !tracks.isEmpty else { return nil }
        return .video(url, loops: true)
    }

    nonisolated static func isImage(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(source) > 0 {
            return true
        }
        return CIImage(contentsOf: url) != nil
    }
}
