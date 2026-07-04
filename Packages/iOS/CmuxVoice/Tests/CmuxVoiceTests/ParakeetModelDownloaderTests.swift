import Foundation
import Testing
@testable import CmuxVoice

@Suite struct ParakeetModelDownloaderTests {
    @Test func filtersHuggingFaceTreeToV3Int8RequiredFiles() throws {
        let json = """
        [
          {"type":"directory","path":"Encoder.mlmodelc"},
          {"type":"file","path":"Encoder.mlmodelc/weights/weight.bin","size":445},
          {"type":"file","path":"EncoderInt4.mlmodelc/weights/weight.bin","size":999},
          {"type":"file","path":"Preprocessor.mlmodelc/model.mil","size":10},
          {"type":"file","path":"Decoder.mlmodelc/coremldata.bin","size":20},
          {"type":"file","path":"JointDecisionv3.mlmodelc/coremldata.bin","size":30},
          {"type":"file","path":"JointDecision.mlmodelc/coremldata.bin","size":999},
          {"type":"file","path":"parakeet_vocab.json","size":3},
          {"type":"file","path":"README.md","size":12}
        ]
        """.data(using: .utf8)!

        let files = try ParakeetModelDownloadFile.files(fromHuggingFaceTreeJSON: json)

        #expect(files.map(\.path) == [
            "Decoder.mlmodelc/coremldata.bin",
            "Encoder.mlmodelc/weights/weight.bin",
            "JointDecisionv3.mlmodelc/coremldata.bin",
            "Preprocessor.mlmodelc/model.mil",
            "parakeet_vocab.json",
        ])
        #expect(ParakeetModelDownloadFile.totalBytes(in: files) == 508)
    }

    @Test func throttlesByteProgressByByteOrFractionThreshold() {
        var throttler = ParakeetDownloadProgressThrottler(totalBytes: 100_000_000)

        #expect(throttler.progressIfNeeded(downloadedBytes: 200_000) == nil)

        let byteThresholdUpdate = throttler.progressIfNeeded(downloadedBytes: 262_144)
        #expect(byteThresholdUpdate?.phaseDescription == "downloading")
        #expect(isApproximately(byteThresholdUpdate?.fractionCompleted, 0.00262144))

        #expect(throttler.progressIfNeeded(downloadedBytes: 400_000) == nil)

        let fractionThresholdUpdate = throttler.progressIfNeeded(downloadedBytes: 762_144)
        #expect(fractionThresholdUpdate?.phaseDescription == "downloading")
        #expect(isApproximately(fractionThresholdUpdate?.fractionCompleted, 0.00762144))

        let finalUpdate = throttler.progressIfNeeded(downloadedBytes: 100_000_000)
        #expect(finalUpdate == ParakeetDownloadProgress(fractionCompleted: 1, phaseDescription: "downloading"))
    }

    @Test func existingCompleteFileIsSkippedAndWrongSizeIsNotSkipped() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CmuxVoiceDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = ParakeetModelDownloadFile(path: "Encoder.mlmodelc/weights/weight.bin", size: 4)
        let destination = file.destination(in: root)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try Data([1, 2, 3, 4]).write(to: destination)
        #expect(try file.existingCompleteByteCount(in: root) == 4)

        try Data([1, 2]).write(to: destination)
        #expect(try file.existingCompleteByteCount(in: root) == nil)
    }

    private func isApproximately(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 0.0000001
    }
}
