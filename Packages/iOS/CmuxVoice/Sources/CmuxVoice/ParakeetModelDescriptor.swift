import FluidAudio
import Foundation

/// Describes one downloadable Parakeet CoreML model entry.
public struct ParakeetModelDescriptor: Equatable, Identifiable, Sendable {
    /// Engine that uses this model.
    public let engineID: VoiceEngineID
    /// HuggingFace repository path.
    public let repositoryPath: String
    /// Local cache folder FluidAudio expects for this model.
    public let folderName: String

    let version: AsrModelVersion
    let encoderPrecision: ParakeetEncoderPrecision
    let requiredFiles: ParakeetRequiredFileSet
    let modelSpecificTopLevelNames: Set<String>

    /// Stable identity.
    public var id: VoiceEngineID { engineID }

    var downloadSpec: ParakeetDownloadDescriptor {
        ParakeetDownloadDescriptor(
            repositoryPath: repositoryPath,
            folderName: folderName,
            requiredFiles: requiredFiles
        )
    }

    public static func == (lhs: ParakeetModelDescriptor, rhs: ParakeetModelDescriptor) -> Bool {
        lhs.engineID == rhs.engineID
            && lhs.repositoryPath == rhs.repositoryPath
            && lhs.folderName == rhs.folderName
    }

    /// Top-level model items needed for this descriptor.
    var requiredTopLevelNames: Set<String> {
        requiredFiles.topLevelNames
    }

    /// NVIDIA Parakeet v3 with the int8 encoder, stored in the v3 repo folder.
    public static let parakeetV3Int8 = ParakeetModelDescriptor(
        engineID: .parakeetV3,
        repositoryPath: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        folderName: "parakeet-tdt-0.6b-v3",
        version: .v3,
        encoderPrecision: .int8,
        requiredFiles: ParakeetRequiredFileSet(
            exactPaths: ["parakeet_vocab.json"],
            directoryPrefixes: [
                "Preprocessor.mlmodelc/",
                "Encoder.mlmodelc/",
                "Decoder.mlmodelc/",
                "JointDecisionv3.mlmodelc/",
            ]
        ),
        modelSpecificTopLevelNames: ["Encoder.mlmodelc"]
    )

    /// NVIDIA Parakeet v3 with the compact int4 encoder, stored in the v3 repo folder.
    public static let parakeetV3Int4 = ParakeetModelDescriptor(
        engineID: .parakeetV3Int4,
        repositoryPath: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        folderName: "parakeet-tdt-0.6b-v3",
        version: .v3,
        encoderPrecision: .int4,
        requiredFiles: ParakeetRequiredFileSet(
            exactPaths: ["parakeet_vocab.json"],
            directoryPrefixes: [
                "Preprocessor.mlmodelc/",
                "EncoderInt4.mlmodelc/",
                "Decoder.mlmodelc/",
                "JointDecisionv3.mlmodelc/",
            ]
        ),
        modelSpecificTopLevelNames: ["EncoderInt4.mlmodelc"]
    )

    /// NVIDIA Parakeet v2 English model with the int8 encoder.
    public static let parakeetV2Int8 = ParakeetModelDescriptor(
        engineID: .parakeetV2,
        repositoryPath: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
        folderName: "parakeet-tdt-0.6b-v2",
        version: .v2,
        encoderPrecision: .int8,
        requiredFiles: ParakeetRequiredFileSet(
            exactPaths: ["parakeet_vocab.json"],
            directoryPrefixes: [
                "Preprocessor.mlmodelc/",
                "Encoder.mlmodelc/",
                "Decoder.mlmodelc/",
                "JointDecision.mlmodelc/",
            ]
        ),
        modelSpecificTopLevelNames: [
            "Preprocessor.mlmodelc",
            "Encoder.mlmodelc",
            "Decoder.mlmodelc",
            "JointDecision.mlmodelc",
            "parakeet_vocab.json",
        ]
    )

    /// All downloadable Parakeet descriptors in settings order.
    public static let allDownloadable: [ParakeetModelDescriptor] = [
        .parakeetV3Int8,
        .parakeetV3Int4,
        .parakeetV2Int8,
    ]

    /// Descriptor for a downloadable engine.
    public static func descriptor(for engineID: VoiceEngineID) -> ParakeetModelDescriptor? {
        allDownloadable.first { $0.engineID == engineID }
    }
}

struct ParakeetDownloadDescriptor: Equatable, Sendable {
    let repositoryPath: String
    let folderName: String
    let requiredFiles: ParakeetRequiredFileSet
}

/// Describes the optional CTC add-on used for Parakeet vocabulary boosting.
public struct ParakeetVocabularyBoostDescriptor: Equatable, Sendable {
    /// HuggingFace repository path.
    public let repositoryPath: String
    /// Local cache folder FluidAudio expects for CTC rescoring.
    public let folderName: String
    let requiredFiles: ParakeetRequiredFileSet

    var downloadSpec: ParakeetDownloadDescriptor {
        ParakeetDownloadDescriptor(
            repositoryPath: repositoryPath,
            folderName: folderName,
            requiredFiles: requiredFiles
        )
    }

    /// The CTC 110M add-on used by `SlidingWindowAsrManager`.
    public static let ctc110m = ParakeetVocabularyBoostDescriptor(
        repositoryPath: "FluidInference/parakeet-ctc-110m-coreml",
        folderName: "parakeet-ctc-110m-coreml",
        requiredFiles: ParakeetRequiredFileSet(
            exactPaths: [
                "vocab.json",
                "tokenizer.json",
            ],
            directoryPrefixes: [
                "MelSpectrogram.mlmodelc/",
                "AudioEncoder.mlmodelc/",
            ]
        )
    )
}

struct ParakeetRequiredFileSet: Equatable, Sendable {
    let exactPaths: Set<String>
    let directoryPrefixes: Set<String>

    var topLevelNames: Set<String> {
        var names = exactPaths
        for prefix in directoryPrefixes {
            if let first = prefix.split(separator: "/", omittingEmptySubsequences: true).first {
                names.insert(String(first))
            }
        }
        return names
    }

    func contains(_ path: String) -> Bool {
        exactPaths.contains(path) || directoryPrefixes.contains { path.hasPrefix($0) }
    }

    func exists(at directory: URL, fileManager: FileManager = .default) -> Bool {
        let exactPathsExist = exactPaths.allSatisfy { path in
            fileManager.fileExists(atPath: directory.appendingPathComponent(path).path)
        }
        let directoriesExist = directoryPrefixes.allSatisfy { prefix in
            guard let first = prefix.split(separator: "/", omittingEmptySubsequences: true).first else {
                return false
            }
            return fileManager.fileExists(atPath: directory.appendingPathComponent(String(first)).path)
        }
        return exactPathsExist && directoriesExist
    }
}
