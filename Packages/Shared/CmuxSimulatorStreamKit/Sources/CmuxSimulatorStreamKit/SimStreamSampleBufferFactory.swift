import CoreMedia
import Foundation

public enum SimStreamSampleBufferError: Error {
    case formatDescriptionCreationFailed(OSStatus)
    case blockBufferCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case emptyParameterSets
}

/// Viewer-side factory turning wire frames into display-ready sample buffers.
///
/// One factory instance corresponds to one `config` message; a new config
/// (rotation, device switch, codec change) means a new factory. Frames are
/// tagged to display immediately, so the display layer never buffers.
public final class SimStreamSampleBufferFactory: Sendable {
    private let formatDescription: CMVideoFormatDescription

    public init(config: SimStreamConfig) throws {
        guard !config.parameterSets.isEmpty else {
            throw SimStreamSampleBufferError.emptyParameterSets
        }
        var format: CMVideoFormatDescription?
        let status = Self.withParameterSetPointers(config.parameterSets) {
            pointers, sizes -> OSStatus in
            switch config.codec {
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: Int32(config.nalUnitHeaderLength),
                    extensions: nil,
                    formatDescriptionOut: &format
                )
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: Int32(config.nalUnitHeaderLength),
                    formatDescriptionOut: &format
                )
            }
        }
        guard status == noErr, let format else {
            throw SimStreamSampleBufferError.formatDescriptionCreationFailed(status)
        }
        self.formatDescription = format
    }

    public func makeSampleBuffer(from frame: SimStreamFrame) throws -> CMSampleBuffer {
        let payload = frame.payload
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw SimStreamSampleBufferError.blockBufferCreationFailed(status)
        }
        status = payload.withUnsafeBytes { source -> OSStatus in
            guard let base = source.baseAddress else { return OSStatus(kCMBlockBufferEmptyBBufErr) }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0,
                dataLength: payload.count)
        }
        guard status == kCMBlockBufferNoErr else {
            throw SimStreamSampleBufferError.blockBufferCreationFailed(status)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(
                value: CMTimeValue(frame.presentationMicroseconds), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = payload.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw SimStreamSampleBufferError.sampleBufferCreationFailed(status)
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true) as? [CFMutableDictionary],
            let first = attachments.first
        {
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !frame.flags.contains(.keyframe) {
                CFDictionarySetValue(
                    first,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }
        return sampleBuffer
    }

    private static func withParameterSetPointers(
        _ parameterSets: [Data],
        _ body: ([UnsafePointer<UInt8>], [Int]) -> OSStatus
    ) -> OSStatus {
        func recurse(
            _ remaining: ArraySlice<Data>,
            _ pointers: [UnsafePointer<UInt8>],
            _ sizes: [Int]
        ) -> OSStatus {
            guard let next = remaining.first else {
                return body(pointers, sizes)
            }
            return next.withUnsafeBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return OSStatus(-1) }
                return recurse(
                    remaining.dropFirst(),
                    pointers + [base.assumingMemoryBound(to: UInt8.self)],
                    sizes + [bytes.count]
                )
            }
        }
        return recurse(parameterSets[...], [], [])
    }
}
