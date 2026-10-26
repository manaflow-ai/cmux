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
        // Each set's start offset in `joined`: the sizes' running sum.
        let offsets = sizes.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1) }.dropLast()
        let status: OSStatus = joined.withUnsafeBufferPointer { buffer in
            // SAFETY: `joined` is not empty (every set is), so buffer has a base address.
            guard let base = unsafe buffer.baseAddress else { return -1 }
            // SAFETY: every offset is below joined.count (each set is non-empty and the
            // offsets are the sizes' running sum), so each pointer is inside buffer.
            let pointers = unsafe offsets.map { unsafe base + $0 }
            switch codec {
            case .h264:
                // SAFETY: Core Media reads sizes[i] bytes at pointers[i], which ends inside
                // buffer, during the call only (it copies the sets into the description),
                // and writes one +1 description to the local `description`.
                return unsafe CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sizes.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            case .hevc:
                // SAFETY: as for H.264 above.
                return unsafe CMVideoFormatDescriptionCreateFromHEVCParameterSets(
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
        // SAFETY: with a nil memory block and no custom source, Core Media allocates
        // lengthPrefixed.count bytes itself and writes one +1 block to the local `block`.
        var status = unsafe CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: lengthPrefixed.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: lengthPrefixed.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { return nil }
        status = lengthPrefixed.withUnsafeBytes { raw in
            // SAFETY: raw views the non-empty `lengthPrefixed`, so it has a base address.
            guard let base = unsafe raw.baseAddress else { return OSStatus(-1) }
            // SAFETY: copies raw.count (= lengthPrefixed.count) bytes from base into the
            // block, which was created with exactly that many bytes, during the call only.
            return unsafe CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: raw.count)
        }
        guard status == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = lengthPrefixed.count
        // SAFETY: Core Media reads one size from the local `size` (one entry, as passed)
        // and writes one +1 sample to the local `sample`; there is no timing array.
        status = unsafe CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }
}
