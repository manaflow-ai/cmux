@preconcurrency import AVFoundation
import CmuxSimulator
import CoreImage
import Foundation
import ImageIO

/// Classifies host media files for native Simulator camera injection.
public struct SimulatorCameraSourceClassifier: Sendable {
    /// Creates a classifier for host image and video files.
    public init() {}

    /// Returns the native camera configuration represented by a media file.
    public func configuration(for url: URL) async -> SimulatorCameraConfiguration? {
        let isImageFile = await Task.detached { [self] in
            isImage(url)
        }.value
        if isImageFile { return .image(url) }

        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              !tracks.isEmpty else { return nil }
        return .video(url, loops: true)
    }

    nonisolated func isImage(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(source) > 0 {
            return true
        }
        return CIImage(contentsOf: url) != nil
    }
}
