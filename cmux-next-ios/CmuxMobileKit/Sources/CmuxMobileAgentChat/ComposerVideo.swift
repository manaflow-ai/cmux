#if os(iOS)
import AVFoundation
import CmuxMobileTransport
import CoreTransferable
import UIKit
import UniformTypeIdentifiers

/// A video picked in Photos, copied out of the picker's temporary file into this app's own
/// temporary folder (the picker deletes its copy when the load returns). The composer keeps it
/// by URL, as a large file from Files: it streams to the Mac at send.
struct PickedMovie: Transferable {
    let url: URL

    /// Where picked videos are copied; `sweep()` empties what earlier launches left.
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-composer-videos", isDirectory: true)
    }

    /// Deletes copies older than a day (a draft's video is sent or dropped well before then).
    static func sweep(now: Date = Date()) {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for folder in folders {
            let made = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if now.timeIntervalSince(made) > 86_400 { try? manager.removeItem(at: folder) }
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedMovie.sweep()
            let folder = PickedMovie.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// The frames the agent sees of an attached video (the Mac's `video.info`, read with
/// AVFoundation off the main thread): four even frames at most 1024 px, JPEG.
enum ComposerVideoReader {
    static let frameCount = 4
    static let maxSide: CGFloat = 1024

    /// The video at `url`, inside its security scope; nil when it can't be read (the
    /// video then goes as its link alone, as on the Mac).
    static func read(_ url: URL) async -> AgentVideo? {
        let access = ScopedFile(url).open()
        defer { access.close() }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            guard duration.seconds.isFinite, duration.seconds > 0,
                  let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let size = natural.applying(transform)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxSide, height: maxSide)
            var frames: [AgentVideo.Frame] = []
            for index in 0..<frameCount {
                try Task.checkCancellation()
                let seconds = duration.seconds * (Double(index) + 0.5) / Double(frameCount)
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                guard let image = try? await generator.image(at: time).image,
                      let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) else { continue }
                frames.append(AgentVideo.Frame(atMs: Int((seconds * 1000).rounded()), jpeg: jpeg))
            }
            guard !frames.isEmpty else { return nil }
            return AgentVideo(durationMs: Int((duration.seconds * 1000).rounded()),
                              width: Int(abs(size.width).rounded()), height: Int(abs(size.height).rounded()), frames: frames)
        } catch {
            return nil
        }
    }
}
#endif
