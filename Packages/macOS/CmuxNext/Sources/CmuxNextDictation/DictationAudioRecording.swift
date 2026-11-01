public import AVFoundation
import CmuxNextCompat
import Darwin
public import Foundation
import os

/// A finished session's recording: a WAV file of any length on this Mac, and its bytes too when
/// they fit in a prompt (``DictationAudioRecording/inlinePromptBytes``), in which case the file is
/// already gone.
public struct DictationAudio: Equatable, Sendable {
    /// The WAV file; nil when the recording went inline (``data``).
    public var file: URL?
    public var byteCount: Int
    /// The WAV's bytes, when it fits in a prompt as an audio block.
    public var data: Data?
    /// The file the recording wrote (``file``), as the writer left it: a file put at that path
    /// later is another file.
    public var fileIdentity: DictationFileIdentity?

    public init(file: URL? = nil, byteCount: Int, data: Data? = nil, fileIdentity: DictationFileIdentity? = nil) {
        self.file = file
        self.byteCount = byteCount
        self.data = data
        self.fileIdentity = fileIdentity
    }
}

/// Which file a path named when it was read: its device and inode. A file renamed, linked to or
/// written in its place since has another identity (a hard link to the same file keeps it).
public struct DictationFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    /// The identity of the file open at `descriptor`; nil when it can't be read.
    public static func of(descriptor: Int32) -> Self? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return Self(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
    }
}

/// The session's own audio, kept for a harness that takes voice input
/// (`promptCapabilities.audio`): 16 kHz mono 16-bit PCM, what speech models
/// expect, written as one WAV file as it is heard.
///
/// The level meter feeds it each tap buffer (``DictationAudioLevelMeter/recording``).
/// Each buffer is downmixed to its first channel and box-averaged to 16 kHz in
/// the tap. A session of any length records: at most ``flushSamples`` wait in
/// memory, and each full second goes to the file on ``writer``, never on the
/// tap's thread or the main actor. From input below 16 kHz it keeps nothing
/// and ``finish()`` returns nil: that session goes as its transcript alone,
/// and ``omission`` says why. So does a recording whose file could not be
/// written or read back (a full disk, a folder that is not writable):
/// ``Omission/writeFailed``, so the person learns the audio was lost.
///
/// The tap is a synchronous audio callback, so it cannot hop to an actor; one
/// unfair lock guards the state, and each tap holds it for one buffer's append.
public final class DictationAudioRecording: Sendable {
    /// Why a session's audio was left out of its prompt.
    public enum Omission: String, Equatable, Sendable {
        /// The input came in below 16 kHz (a narrowband headset).
        case narrowband
        /// The recording's file could not be written or read back (a full disk, a folder that is
        /// not writable): the audio is lost, and the person is told.
        case writeFailed
    }

    public static let sampleRate: Double = 16_000
    /// A recording up to this size goes in the prompt as an audio block (its base64 stays well
    /// inside one prompt frame); a larger one goes as its file.
    public static let inlinePromptBytes = 4 * 1024 * 1024
    /// One second: what waits in memory before it goes to the file.
    static let flushSamples = 16_000

    private struct State {
        var pending: [Int16] = []
        var written = 0
        var omitted: Omission?
        var finished = false
        /// The input summed toward the next output sample, and how much of it.
        var partial: (sum: Double, count: Double) = (0, 0)
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let file: URL
    /// The recording's own folder, removed with its file (``init(folder:)``); nil for a file given
    /// alone (``init(file:)``), whose folder stays.
    private let folder: URL?
    /// The serial queue every file step runs on, in the order the state lock saw them.
    let writer: DispatchQueue
    /// The file as ``writer`` writes it. Only blocks on ``writer`` take this lock, one at a time,
    /// so it is never contended; it carries the state across that queue's blocks.
    private let output = Mutex(Output())

    private struct Output {
        /// Opened at the first flush.
        var handle: FileHandle?
        /// A write failed (a full disk) or the recording was discarded: the session goes as its
        /// transcript alone.
        var failed = false
    }

    /// A recording into `file` (made owner-only at the first second heard).
    public init(file: URL) {
        writer = Self.writerQueue()
        self.file = file
        folder = nil
    }

    /// A recording that owns `folder` (a fresh upload folder of the chat, made owner-only at the
    /// first second heard; by default one under this user's temporary folder): its file is
    /// `Recording.wav` there, and a recording sent inline or discarded removes the folder.
    public init(folder: URL? = nil) {
        writer = Self.writerQueue()
        let folder = folder
            ?? FileManager.default.temporaryDirectory.appending(path: "cmux-dictation", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        self.folder = folder
        file = folder.appending(path: "Recording.wav")
    }

    private static func writerQueue() -> DispatchQueue {
        DispatchQueue(label: "com.cmuxterm.dictation.recording", qos: .utility)
    }

    /// Removes the file, and the recording's own folder with it.
    private func removeFile() {
        try? FileManager.checked.removeItem(at: folder ?? file)
    }

    /// Folds one tap buffer in.
    public func record(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let input = UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
        append(input, sampleRate: buffer.format.sampleRate)
    }

    /// Folds samples at `sampleRate` in (tests feed these directly). Each output sample is the
    /// mean of the input span it covers; an input sample that straddles two spans is split between
    /// them by weight, so a rate that is no whole multiple of 16 kHz (44.1, 24 kHz) stays level.
    /// Input below 16 kHz (a narrowband headset) is not recorded: the session goes as text alone.
    public func append(_ input: UnsafeBufferPointer<Float>, sampleRate: Double) {
        // The closure runs before withLockUnchecked returns, so the buffer is still valid in it.
        state.withLockUnchecked { state in
            guard state.omitted == nil, !state.finished else { return }
            guard sampleRate >= Self.sampleRate else {
                state.omitted = .narrowband
                state.pending = []
                return
            }
            // Input samples per output sample.
            let step = sampleRate / Self.sampleRate
            for value in input {
                let sample = Double(value.isFinite ? value : 0)
                var left = 1.0
                while left > 0 {
                    let take = min(left, step - state.partial.count)
                    state.partial.sum += sample * take
                    state.partial.count += take
                    left -= take
                    guard state.partial.count >= step - 1e-9 else { continue }
                    let mean = max(-1, min(1, state.partial.sum / step))
                    state.pending.append(Int16(mean * Double(Int16.max)))
                    state.partial = (0, 0)
                }
            }
            guard state.pending.count >= Self.flushSamples else { return }
            defer { state.pending = [] }
            state.written += state.pending.count
            // Enqueued under the lock, so the writer runs the writes in the order `written` counted
            // them and before any finish or discard that read `written` after this one (async: no wait).
            let full = state.pending
            writer.async { self.write(full) }
        }
    }

    /// Why ``finish()`` has nothing, when the session's audio was left out rather than silent. Read
    /// it after ``finish()`` returns: a write failure is set on ``writer`` before the finish answers.
    public var omission: Omission? { state.withLock { $0.omitted } }

    /// Ends the recording: the last samples and the WAV header go to the file on ``writer``. A
    /// recording that fits ``inlinePromptBytes`` comes back as bytes and its file is removed; a
    /// larger one comes back as its file. Nil when nothing was heard or the input was narrowband.
    public func finish() async -> DictationAudio? {
        await withCheckedContinuation { continuation in
            // Enqueued under the lock, after every write a tap took before it (see `append`).
            state.withLock { state in
                // Ended already (a discard, an earlier finish): answer after what it queued, so the
                // caller sees its file gone once this returns.
                guard !state.finished else {
                    writer.async { continuation.resume(returning: nil) }
                    return
                }
                state.finished = true
                let (rest, total, omitted) = (state.pending, state.written + state.pending.count, state.omitted)
                state.pending = []
                state.written = total
                writer.async {
                    continuation.resume(returning: self.close(rest: rest, samples: total, omitted: omitted))
                }
            }
        }
    }

    /// Removes the file (a cancelled or superseded session), on the writer queue after what came
    /// before it. A ``finish()`` after this answers nil once the file is gone.
    public func discard() {
        // Enqueued under the lock, as `append` and `finish` enqueue theirs: the writer runs a write,
        // a finish's close, this delete and a later finish's answer in the order the lock saw them.
        state.withLock { state in
            state.finished = true
            writer.async {
                // Final: a later write or finish finds `failed` and keeps nothing.
                self.output.withLock { output in
                    output.failed = true
                    try? output.handle?.close()
                    output.handle = nil
                }
                self.removeFile()
            }
        }
    }

    // MARK: - On `writer`

    private func write(_ samples: [Int16]) {
        output.withLock { write(samples, into: &$0) }
    }

    private func write(_ samples: [Int16], into output: inout Output) {
        guard !output.failed, !samples.isEmpty else { return }
        do {
            if output.handle == nil { output.handle = try open() }
            try samples.withUnsafeBytes { try output.handle?.write(contentsOf: $0) }
        } catch {
            output.failed = true
            try? output.handle?.close()
            output.handle = nil
        }
    }

    private func open() throws -> FileHandle {
        let manager = FileManager.checked
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard manager.createFile(atPath: file.path, contents: Self.header(samples: 0), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        return handle
    }

    private func close(rest: [Int16], samples: Int, omitted: Omission?) -> DictationAudio? {
        var identity: DictationFileIdentity?
        let closed: Bool = output.withLock { output in
            write(rest, into: &output)
            defer {
                try? output.handle?.close()
                output.handle = nil
                // Final: nothing reopens a finished recording's file.
                output.failed = true
            }
            guard omitted == nil, samples > 0, !output.failed, let handle = output.handle else { return false }
            do {
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Self.header(samples: samples))
                try handle.synchronize()
                identity = DictationFileIdentity.of(descriptor: handle.fileDescriptor)
                return true
            } catch {
                return false
            }
        }
        guard closed else {
            // Heard, not left out, yet not saved: a write failed (a discard never reaches this close).
            if omitted == nil, samples > 0 { lost() }
            removeFile()
            return nil
        }
        let dataBytes = samples * MemoryLayout<Int16>.size
        // A prompt's audio block is a plain 44-byte-header WAV, what every model reads; the file's
        // samples follow its own (longer) header.
        let inlineBytes = 44 + dataBytes
        guard inlineBytes <= Self.inlinePromptBytes else {
            return DictationAudio(file: file, byteCount: Self.headerBytes + dataBytes, fileIdentity: identity)
        }
        let data = (try? Data(blockingContentsOf: file)).map { Self.plainHeader(samples: samples) + $0.dropFirst(Self.headerBytes) }
        removeFile()
        if data == nil { lost() }
        return data.map { DictationAudio(byteCount: inlineBytes, data: $0) }
    }

    /// The recording was heard but could not be saved: ``omission`` says so.
    private func lost() {
        state.withLock { $0.omitted = $0.omitted ?? .writeFailed }
    }

    /// The file's header length: RIFF's 12 bytes, a 36-byte JUNK (or ds64) chunk, the 24-byte fmt
    /// chunk and the data chunk's 8. Fixed, so the samples never move whatever the recording's length.
    static let headerBytes = 80

    /// The file's ``headerBytes``-long header for `samples` samples of 16 kHz mono 16-bit PCM. Up to
    /// 4 GiB of data it is a WAV whose JUNK chunk holds the room RF64 needs; past that the same
    /// bytes are RF64 (EBU Tech 3306): `RF64`, the 64-bit sizes in a ds64 chunk, and the 32-bit
    /// size fields set to 0xFFFFFFFF. No length is too long.
    static func header(samples: Int) -> Data {
        let dataBytes = UInt64(max(samples, 0)) * UInt64(MemoryLayout<Int16>.size)
        let riffBytes = UInt64(headerBytes - 8) + dataBytes
        let large = riffBytes > UInt64(UInt32.max)
        var data = Data(capacity: headerBytes)
        func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        put(large ? "RF64" : "RIFF"); put(large ? UInt32.max : UInt32(riffBytes)); put("WAVE")
        if large {
            put("ds64"); put(UInt32(28))
            put(riffBytes); put(dataBytes); put(UInt64(max(samples, 0))); put(UInt32(0))
        } else {
            put("JUNK"); put(UInt32(28)); data.append(Data(count: 28))
        }
        putFormat(into: &data)
        put("data"); put(large ? UInt32.max : UInt32(dataBytes))
        return data
    }

    /// A plain 44-byte WAV header for `samples` samples (at most 4 GiB of data: a prompt's audio).
    static func plainHeader(samples: Int) -> Data {
        let bytes = UInt32(clamping: max(samples, 0) * MemoryLayout<Int16>.size)
        var data = Data(capacity: 44)
        func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        put("RIFF"); put(36 &+ bytes); put("WAVE")
        putFormat(into: &data)
        put("data"); put(bytes)
        return data
    }

    /// The fmt chunk: PCM, mono, 16 kHz, 16-bit.
    private static func putFormat(into data: inout Data) {
        let rate = UInt32(sampleRate)
        func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        put("fmt "); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
    }
}
