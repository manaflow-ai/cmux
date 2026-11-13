// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox

// The VideoToolbox and CoreMedia helpers of a preview session (PreviewStreamSession).
extension PreviewStreamSession {
    /// A hardware H.264 encoder tuned for low latency: no frame reordering, real time, a keyframe
    /// at least every two seconds (a late-joining decoder catches up quickly).
    static func makeEncoder(width: Int, height: Int) -> VTCompressionSession? {
        let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: specification, imageBufferAttributes: nil,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &session)
        guard status == noErr, let session else { return nil }
        let bitrate = max(500_000, width * height * 4)
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_ExpectedFrameRate: framesPerSecond,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
        ]
        VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    /// A ScreenCaptureKit frame that carries a new picture (not an idle or blank one).
    static func isComplete(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return first[kCMSampleAttachmentKey_NotSync] as? Bool != true
    }

    static func bytes(of sample: CMSampleBuffer) -> Data? {
        guard let block = sample.dataBuffer else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        return status == noErr ? data : nil
    }

    static func parameterSets(_ format: CMFormatDescription) -> (sps: Data, pps: Data)? {
        func set(_ index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                    nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard let sps = set(0), let pps = set(1) else { return nil }
        return (sps, pps)
    }
}
