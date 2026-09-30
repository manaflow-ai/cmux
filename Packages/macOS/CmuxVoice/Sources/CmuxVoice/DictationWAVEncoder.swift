import Foundation

/// Wraps 16-bit mono PCM samples in a WAV container for upload.
enum DictationWAVEncoder {
    static func wav(pcm16 samples: Data, sampleRate: Int) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var data = Data()
        data.append(Data("RIFF".utf8))
        data.appendLittleEndian(UInt32(36 + samples.count))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1)) // PCM
        data.appendLittleEndian(UInt16(channels))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(byteRate))
        data.appendLittleEndian(UInt16(blockAlign))
        data.appendLittleEndian(UInt16(bitsPerSample))
        data.append(Data("data".utf8))
        data.appendLittleEndian(UInt32(samples.count))
        data.append(samples)
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
