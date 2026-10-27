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
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
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
/// After the parser drops a unit, frames reference a picture the decoder never
/// had, so slices are skipped until the next keyframe makes a sample, as
/// Chromium's `media/gpu/mac/vt_video_decode_accelerator_mac.cc` drops
/// frames while `waiting_for_idr_`.
/// Called only from one pipe's readability handler, which Foundation runs
/// serially, so its state is behind a lock only to be `Sendable`.
final class AndroidFrameAssembler: Sendable {
    /// A sample buffer handed from the pipe queue to the main actor.
    // crash-allow: CMSampleBuffer is immutable once made and Core Media retains it across threads.
    struct Sample: @unchecked Sendable {
        let buffer: CMSampleBuffer
    }

    private struct State {
        var parser: AnnexBParser
        var sps: Data?
        var pps: Data?
        var format: CMVideoFormatDescription?
        /// A unit was dropped since the last keyframe sample: slices are skipped.
        var awaitingKeyframe = false
    }

    private let state: Mutex<State>

    init(maxUnitBytes: Int = AnnexBParser.defaultMaxUnitBytes) {
        state = Mutex(State(parser: AnnexBParser(maxUnitBytes: maxUnitBytes)))
    }

    func samples(from chunk: Data) -> [Sample] {
        state.withLock { state in
            state.parser.cut(chunk).compactMap { cut in
                guard case let .unit(unit) = cut else {
                    state.awaitingKeyframe = true
                    return nil
                }
                let kind = H264Unit(unit).kind
                switch kind {
                case .sps:
                    if state.sps != unit { state.format = nil }
                    state.sps = unit
                case .pps:
                    if state.pps != unit { state.format = nil }
                    state.pps = unit
                case .keyframe, .frame:
                    if kind == .frame, state.awaitingKeyframe { return nil }
                    if state.format == nil, let sps = state.sps, let pps = state.pps { state.format = Self.format(sps: sps, pps: pps) }
                    guard let format = state.format, let sample = Self.sample(unit, format: format) else { return nil }
                    if kind == .keyframe { state.awaitingKeyframe = false }
                    return Sample(buffer: sample)
                case .other:
                    break
                }
                return nil
            }
        }
    }

    /// The format of one SPS and PPS; nil when Core Media rejects them (internal for the fuzz suite's oracle).
    static func format(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        guard !sps.isEmpty, !pps.isEmpty else { return nil }
        // One buffer holds both sets, so both pointers are valid for the one call.
        let joined = [UInt8](sps) + [UInt8](pps)
        let sizes = [sps.count, pps.count]
        var format: CMVideoFormatDescription?
        let status = joined.withUnsafeBufferPointer { buffer -> OSStatus in
            // SAFETY: `joined` is not empty (neither set is), so the buffer has a base address.
            guard let base = unsafe buffer.baseAddress else { return -1 }
            // SAFETY: Core Media reads sizes[0] bytes at base (the SPS) and sizes[1] bytes at
            // base + sizes[0] (the PPS), both inside `joined`, during the call only (it copies the
            // sets into the description), and writes one +1 description to the local `format`.
            return unsafe CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: [base, base + sps.count],
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    /// `unit` as one length-prefixed (AVCC) sample, marked to display at once.
    static func sample(_ unit: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var avcc = Data(capacity: 4 + unit.count)
        // decode-trap-allow: AnnexBParser drops a unit past maxUnitBytes (8 MiB), so the length fits a u32.
        avcc.appendBigEndian(UInt32(unit.count))
        avcc.append(unit)
        var block: CMBlockBuffer?
        // SAFETY: with a nil memory block and no custom source, Core Media allocates avcc.count
        // bytes itself and writes one +1 block to the local `block`.
        guard unsafe CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr,
            let block else { return nil }
        let copied = avcc.withUnsafeBytes { raw -> OSStatus in
            // SAFETY: raw views the non-empty `avcc` (4 length bytes at least), so it has a base address.
            guard let base = unsafe raw.baseAddress else { return -1 }
            // SAFETY: copies raw.count (= avcc.count) bytes from base into the block, which was
            // created with exactly that many bytes, during the call only.
            return unsafe CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: raw.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        // SAFETY: Core Media reads one size from the local `size` (one entry, as passed) and
        // writes one +1 sample to the local `sample`; there is no timing array.
        guard unsafe CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
            let sample else { return nil }
        // Live: show each frame when it arrives, no presentation clock. The attachments array
        // holds the sample's own mutable dictionaries (toll-free bridged), so setting the key on
        // the first one marks the sample itself.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           let first = (attachments as NSArray).firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }
}
