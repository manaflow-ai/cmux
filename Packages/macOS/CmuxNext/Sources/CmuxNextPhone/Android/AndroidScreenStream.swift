import CmuxNextCompat
import CmuxNextWakeups
import CoreMedia
import Foundation

/// A live Android screen: `adb exec-out screenrecord --output-format=h264 -`
/// streams H.264 over adb, and each frame becomes a compressed
/// `CMSampleBuffer` that ``PhoneScreenView`` hands to an
/// `AVSampleBufferDisplayLayer`, which decodes in hardware. cmux decodes and
/// copies nothing itself. screenrecord stops at its time limit (3 minutes);
/// its exit starts the next one while the stream is on.
@MainActor
final class AndroidScreenStream {
    /// Spawns and stops adb off the main thread, in call order (a fork can take hundreds of ms).
    private let launcher = ProcessLauncher(label: "com.cmuxterm.next.android-screen", priority: .userVisible)
    private let adb: String
    private let serial: String
    private var process: Process?
    private var running = false
    /// Called on the main thread with each frame, ready to enqueue.
    var onSample: (@MainActor (CMSampleBuffer) -> Void)?
    /// Called when the stream cannot start or adb ended with an error.
    var onError: (@MainActor (PhoneError) -> Void)?

    init(adb: String, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    func start() {
        guard !running else { return }
        running = true
        launch()
    }

    /// Ends the stream: no adb process, no frames.
    func stop() {
        running = false
        if let process { launcher.terminate(process) }
        process = nil
    }

    private func launch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["-s", serial, "exec-out", "screenrecord", "--output-format=h264", "--bit-rate", "8000000", "-"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let decoder = AndroidFrameAssembler()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data: Data
            switch handle.readReady() {
            case .bytes(let ready): data = ready
            case .retry: return
            case .end: handle.readabilityHandler = nil; return
            }
            for sample in decoder.samples(from: data) {
                // task-owner: one main-actor hop per frame; it ends when the frame is enqueued.
                Task { @MainActor [weak self] in self?.onSample?(sample.buffer) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            // task-owner: restarts screenrecord after its time limit, or reports the failure; ends at once.
            Task { @MainActor [weak self] in self?.ended(finished, status: status) }
        }
        self.process = process
        // The spawn runs off main, in order with a later stop's terminate.
        launcher.launch(process) { error in
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.process === process else { return }
                self.running = false
                self.process = nil
                self.onError?(.commandFailed(command: "adb screenrecord", status: -1, stderr: message))
            }
        }
    }

    private func ended(_ finished: Process, status: Int32) {
        guard finished === process else { return }
        process = nil
        guard running else { return }
        if status == 0 { launch() } else {
            running = false
            onError?(.commandFailed(command: "adb screenrecord", status: status, stderr: ""))
        }
    }
}

/// Turns stream bytes into sample buffers: parameter sets make the format,
/// each slice becomes one length-prefixed (AVCC) sample shown at once.
/// Called only from one pipe's readability handler, which Foundation runs
/// serially, so its state is behind a lock only to be `Sendable`.
final class AndroidFrameAssembler: Sendable {
    /// A sample buffer handed from the pipe queue to the main actor.
    // crash-allow: CMSampleBuffer is immutable once made and Core Media retains it across threads.
    struct Sample: @unchecked Sendable {
        let buffer: CMSampleBuffer
    }

    private struct State {
        var parser = AnnexBParser()
        var sps: Data?
        var pps: Data?
        var format: CMVideoFormatDescription?
    }

    private let state = Mutex(State())

    func samples(from chunk: Data) -> [Sample] {
        state.withLock { state in
            state.parser.append(chunk).compactMap { unit in
                let nal = H264Unit(unit)
                switch nal.kind {
                case .sps:
                    if state.sps != unit { state.format = nil }
                    state.sps = unit
                case .pps:
                    if state.pps != unit { state.format = nil }
                    state.pps = unit
                case .keyframe, .frame:
                    if state.format == nil, let sps = state.sps, let pps = state.pps { state.format = Self.format(sps: sps, pps: pps) }
                    guard let format = state.format else { return nil }
                    return Self.sample(unit, format: format).map(Sample.init(buffer:))
                case .other:
                    break
                }
                return nil
            }
        }
    }

    private static func format(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes -> OSStatus in
                guard let s = spsBytes.bindMemory(to: UInt8.self).baseAddress, let p = ppsBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                let pointers = [s, p]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    private static func sample(_ unit: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var length = UInt32(unit.count).bigEndian
        var avcc = Data(bytes: &length, count: 4)
        avcc.append(unit)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
              let block,
              avcc.withUnsafeBytes({ bytes -> OSStatus in
                  guard let base = bytes.baseAddress else { return -1 }
                  return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
              }) == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        // Live: show each frame when it arrives, no presentation clock.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
