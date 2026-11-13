// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import CmuxNextComputerUse
import CmuxNextDaemon
import CmuxNextActions
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import os
@testable import CmuxNextMacScreen
import Testing
import VideoToolbox

// Shared fixtures of the live preview tests (ComputerUsePreviewTests, ComputerUsePreviewStreamTests).

/// The App's side for the presenter: the setting on, and an agent chat focused.
@MainActor final class PreviewHost: ComputerUsePreviewHost {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let surface = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    init() { container.addSubview(surface) }
    var computerUseLivePreviewEnabled: Bool { true }
    func computerUsePreviewFocus() -> (surface: ComputerUsePreviewSurface, host: NSView)? { (.chat(session: "chat-1"), surface) }
}

/// What the reader delivered, in order (the reader runs on the test's thread here).
nonisolated final class Collected: Sendable {
    private let lock = OSAllocatedUnfairLock<[ComputerUsePreviewStream.Output]>(initialState: [])
    var outputs: [ComputerUsePreviewStream.Output] { lock.withLock { $0 } }
    func add(_ output: ComputerUsePreviewStream.Output) { lock.withLock { $0.append(output) } }
    var samples: [CMSampleBuffer] {
        outputs.compactMap { if case .sample(let sample) = $0 { sample } else { nil } }
    }
    var kinds: [String] {
        outputs.map {
            switch $0 {
            case .sample: "sample"
            case .closed: "closed"
            case .stillReady: "still"
            case .status: "status"
            }
        }
    }
}

/// A real JPEG of a gray `width` x `height` picture.
nonisolated func jpeg(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(gray: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

nonisolated func message(_ kind: UInt8, _ payload: Data) -> Data {
    let n = UInt32(payload.count)
    return Data([kind, UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]) + payload
}

nonisolated func socketPair() throws -> (Int32, Int32) {
    var fds: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
    return (fds[0], fds[1])
}

nonisolated struct Encoded: Sendable {
    var sps: Data
    var pps: Data
    var avcc: Data
}

nonisolated func encodeOneFrame(width: Int32, height: Int32) throws -> Encoded {
    var session: VTCompressionSession?
    #expect(VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
                                       encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                       outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr)
    let compressor = try #require(session)
    defer { VTCompressionSessionInvalidate(compressor) }
    VTSessionSetProperty(compressor, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(compressor, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    var pixels: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, Int(width), Int(height), kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess)
    let buffer = try #require(pixels)
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, 0x80, CVPixelBufferGetBytesPerRow(buffer) * Int(height))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let output = OutputBox()
    let properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
    #expect(VTCompressionSessionEncodeFrame(compressor, imageBuffer: buffer, presentationTimeStamp: .zero, duration: .invalid,
                                            frameProperties: properties, infoFlagsOut: nil) { status, _, sample in
        if status == noErr, let sample { output.take(sample) }
    } == noErr)
    #expect(VTCompressionSessionCompleteFrames(compressor, untilPresentationTimeStamp: .invalid) == noErr)
    return try #require(output.encoded)
}

/// The encoder's one output, taken apart in its callback (CMSampleBuffer is not Sendable).
nonisolated final class OutputBox: Sendable {
    private let lock = OSAllocatedUnfairLock<Encoded?>(initialState: nil)
    var encoded: Encoded? { lock.withLock { $0 } }
    func take(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample),
              let sps = Self.parameterSet(format, 0), let pps = Self.parameterSet(format, 1) else { return }
        var avcc = Data(count: CMBlockBufferGetDataLength(block))
        let copied = avcc.withUnsafeMutableBytes { bytes in
            bytes.baseAddress.map { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: $0) }
                ?? kCMBlockBufferBadPointerParameterErr
        }
        guard copied == noErr else { return }
        let encoded = Encoded(sps: sps, pps: pps, avcc: avcc)
        lock.withLock { $0 = encoded }
    }

    private static func parameterSet(_ format: CMFormatDescription, _ index: Int) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                 parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                 nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
        return Data(bytes: pointer, count: size)
    }
}
