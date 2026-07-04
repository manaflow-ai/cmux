@preconcurrency import CoreML
import FluidAudio
public import Foundation

/// Downloads Parakeet v3 through FluidAudio.
public struct FluidAudioParakeetModelDownloader: ParakeetModelDownloading {
    /// Creates the real FluidAudio-backed downloader.
    public init() {}

    /// Download the Parakeet v3 int8 model and compile it for CoreML.
    /// - Parameters:
    ///   - directory: The custom model directory root.
    ///   - progress: Receives mapped progress snapshots.
    public func download(
        to directory: URL,
        progress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
    ) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        _ = try await AsrModels.downloadAndLoad(
            to: directory,
            configuration: configuration,
            version: .v3,
            encoderPrecision: .int8,
            encoderComputeUnits: nil,
            progressHandler: { fluidProgress in
                progress(Self.progress(from: fluidProgress))
            }
        )
    }

    /// Returns whether the FluidAudio-required v3 int8 model files exist.
    /// - Parameter directory: The custom model directory root.
    /// - Returns: `true` when the model is installed.
    public static func modelsExist(at directory: URL) -> Bool {
        AsrModels.modelsExist(at: directory, version: .v3, encoderPrecision: .int8)
    }

    private static func progress(from progress: DownloadUtils.DownloadProgress) -> ParakeetDownloadProgress {
        let phase: String
        switch progress.phase {
        case .listing:
            phase = "listing"
        case .downloading:
            phase = "downloading"
        case .compiling:
            phase = "compiling"
        }
        return ParakeetDownloadProgress(
            fractionCompleted: progress.fractionCompleted,
            phaseDescription: phase
        )
    }
}
