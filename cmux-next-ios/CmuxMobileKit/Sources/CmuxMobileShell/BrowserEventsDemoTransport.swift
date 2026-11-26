#if DEBUG && os(iOS)
import CmuxMobileTransport
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
import VideoToolbox

/// Synthetic host messages for the real browser model and its production controls.
/// This transport never opens a network connection or reads account data.
final class BrowserEventsDemoTransport: BrowserStreamOpening, Sendable {
    let scene: String

    init(scene: String) { self.scene = scene }

    func openBrowser(tab: String, url: String?, sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection {
        BrowserEventsDemoConnection(sink: sink, scene: scene)
    }
}

private final class BrowserEventsDemoConnection: BrowserStreamConnection, Sendable {
    private struct State {
        var closed = false
        var task: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let sink: any BrowserStreamSink
    private let scene: String

    init(sink: any BrowserStreamSink, scene: String) {
        self.sink = sink
        self.scene = scene
        // One bounded fixture sequence, cancelled by close. Give the model time to
        // attach the returned connection before the synthetic host welcomes it.
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                self?.emit(#"{"t":"welcome","caps":[]}"#)
                self?.emit(#"{"t":"rb.screen_applied"}"#)
                try await Task.sleep(for: .milliseconds(500))
                self?.showInitialEvent()
                // `video`: a page that never stops moving (a match clip), for the
                // tab grid's frozen frame (verify: BrowserTabFreezeUITests).
                if self?.scene == "video" { await self?.playVideo() }
            } catch { return }
        }
        state.withLock { $0.task = task }
    }

    private func emit(_ json: String) {
        guard !state.withLock({ $0.closed }) else { return }
        sink.browserMessage(Data(json.utf8))
    }

    private func showInitialEvent() {
        switch scene {
        case "select":
            emit(#"""
            {"t":"rb.menu.show","token":2,"menu":{"kind":"select","selected":2,"multiple":false,"items":[
              {"id":0,"type":"group","label":"Teams & projects"},
              {"id":1,"type":"option","label":"Design"},
              {"id":2,"type":"option","label":"R&D"},
              {"id":3,"type":"option","label":"Engineering"},
              {"id":4,"type":"option","label":"Archived","enabled":false}]}}
            """#)
        case "dialog", "confirm":
            emit(#"{"t":"rb.dialog.show","token":3,"dialog":{"kind":"confirm","origin":"https://events.example.test","message":"Save changes to this project?"}}"#)
        case "prompt":
            emit(#"{"t":"rb.dialog.show","token":3,"dialog":{"kind":"prompt","origin":"https://events.example.test","message":"Name this project","default_text":"Research notes"}}"#)
        default: break
        }
    }

    /// 30 fps of real H.264, framed as the Mac sends it, until closed: a bar
    /// sweeping across a background whose hue turns, so any two frames differ.
    private func playVideo() async {
        guard let encoder = DemoVideoEncoder(width: 390, height: 760) else { return }
        var frame: UInt32 = 0
        while !Task.isCancelled, !state.withLock({ $0.closed }) {
            let now = DispatchTime.now().uptimeNanoseconds / 1_000
            let keyframe = frame % 60 == 0
            for unit in encoder.encode(frame: Int(frame), keyframe: keyframe) {
                sink.browserFrame(BrowserStreamFrame(stream: 0, frame: frame, keyframe: keyframe, accessUnit: unit,
                                                     captureMicros: now, receivedMicros: now, ageMicros: 0))
            }
            frame &+= 1
            // The demo clip's frame rate (a bounded fixture pace, cancelled with the connection).
            do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
        }
    }

    func send(message: Data) throws {}

    func send(input: Data, mustDeliver: Bool) throws {
        guard scene == "context",
              let event = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              event["e"] as? String == "pointer", event["kind"] as? String == "up",
              (event["button"] as? NSNumber)?.intValue == 2 else { return }
        // Answer the actual StreamView long-press request, so UIKit presents the
        // production menu through the same deferred callback as a linked Mac.
        emit(#"""
        {"t":"rb.menu.show","token":1,"menu":{"kind":"context","items":[
          {"id":33000,"type":"command","label":"&Back","enabled":true},
          {"id":33001,"type":"command","label":"&Forward","enabled":false},
          {"id":33002,"type":"command","label":"&Reload","enabled":true}]}}
        """#)
    }

    func requestKeyframe() {}
    func noteDecode(micros: UInt32) {}
    func stats() -> BrowserStreamStats { BrowserStreamStats() }
    func nowMicros() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000 }
    func setVisible(_ visible: Bool) {}

    func close() {
        let task = state.withLock { value in
            value.closed = true
            let task = value.task
            value.task = nil
            return task
        }
        task?.cancel()
    }
}

/// A synthetic clip encoded with VideoToolbox (the demo's stand-in for the
/// Mac's page capture). Each call draws one picture and returns its Annex-B
/// access units, parameter sets before a keyframe.
private final class DemoVideoEncoder {
    private let session: VTCompressionSession
    private let width: Int
    private let height: Int

    init?(width: Int, height: Int) {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { return nil }
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        session = created
        self.width = width
        self.height = height
    }

    deinit { VTCompressionSessionInvalidate(session) }

    func encode(frame: Int, keyframe: Bool) -> [Data] {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixels)
        guard let buffer = pixels else { return [] }
        draw(frame: frame, into: buffer)
        let units = OSAllocatedUnfairLock(initialState: [Data]())
        let properties: CFDictionary? = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30),
                                        duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { _, _, sample in
            guard let sample else { return }
            let unit = Self.annexB(sample)
            units.withLock { $0.append(unit) }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return units.withLock { $0 }
    }

    private func draw(frame: Int, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        let hue = CGFloat(frame % 180) / 180
        context.setFillColor(Self.color(hue: hue, brightness: 0.55))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A pitch-like stripe pattern and a bar sweeping across it.
        context.setFillColor(Self.color(hue: hue, brightness: 0.45))
        for row in stride(from: 0, to: height, by: 80) { context.fill(CGRect(x: 0, y: row, width: width, height: 40)) }
        let x = CGFloat(frame * 9 % (width + 120)) - 60
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: x, y: 0, width: 60, height: CGFloat(height)))
        context.fillEllipse(in: CGRect(x: CGFloat(width) - x - 40, y: CGFloat(height) / 2 - 40, width: 80, height: 80))
    }

    private static func color(hue: CGFloat, brightness: CGFloat) -> CGColor {
        // HSB to RGB, saturation 0.6.
        let h = hue * 6, s: CGFloat = 0.6, v = brightness
        let i = Int(h) % 6, f = h - CGFloat(Int(h))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let (r, g, b): (CGFloat, CGFloat, CGFloat) = switch i {
        case 0: (v, t, p)
        case 1: (q, v, p)
        case 2: (p, v, t)
        case 3: (p, q, v)
        case 4: (t, p, v)
        default: (v, p, q)
        }
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// AVCC sample to Annex-B, with the parameter sets in front of a keyframe.
    private static func annexB(_ sample: CMSampleBuffer) -> Data {
        var out = Data()
        let start: [UInt8] = [0, 0, 0, 1]
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let pointer { out.append(contentsOf: start); out.append(pointer, count: size) }
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return out }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard let pointer else { return out }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= length {
            let nal = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            out.append(contentsOf: start)
            out.append(bytes + offset + 4, count: nal)
            offset += 4 + nal
        }
        return out
    }
}
#endif
