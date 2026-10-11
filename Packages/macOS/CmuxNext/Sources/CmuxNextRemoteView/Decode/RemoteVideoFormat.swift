import CoreMedia
import Foundation

/// Core Media plumbing for the decoder: a format description from Annex-B
/// parameter sets, and a sample buffer around length-prefixed NAL units.
nonisolated enum RemoteVideoFormat {
    /// The format description for `parameterSets` (see `RemoteAnnexB.Parsed`).
    static func formatDescription(codec: RemoteVideoCodec, parameterSets: [[UInt8]]) -> CMVideoFormatDescription? {
        guard !parameterSets.isEmpty, parameterSets.allSatisfy({ !$0.isEmpty }) else { return nil }
        // Copy into one buffer so every pointer stays valid for the call.
        let joined = parameterSets.flatMap { $0 }
        let sizes = parameterSets.map(\.count)
        var description: CMVideoFormatDescription?
        let status: OSStatus = joined.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return -1 }
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for size in sizes {
                pointers.append(base + offset)
                offset += size
            }
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sizes.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sizes.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            }
        }
        return status == noErr ? description : nil
    }

    /// One sample around `lengthPrefixed` bytes (copied into the block).
    static func sampleBuffer(lengthPrefixed: [UInt8], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        guard !lengthPrefixed.isEmpty else { return nil }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: lengthPrefixed.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: lengthPrefixed.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { return nil }
        status = lengthPrefixed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: lengthPrefixed.count)
        }
        guard status == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = lengthPrefixed.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }
}
