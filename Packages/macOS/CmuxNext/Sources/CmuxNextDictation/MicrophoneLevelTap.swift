import AVFoundation
import Foundation

/// The meter-only input tap behind the composer's waveform while another app dictates
/// (``MicrophoneActivity``, design/composer-dictation.md). Each tap buffer folds into a
/// ``DictationAudioLevelMeter`` made with no recording: the tap computes the buffer's RMS and drops
/// it, so no sample is kept, written or sent, only the level.
///
/// The engine starts and stops on this actor, off the main thread, as the dictation engines' do
/// (`SFSpeechDictationTranscriber`). It ends the meter's level stream when it stops or when a start
/// fails. A change of default input reaches ``MicrophoneActivity`` as a CoreAudio property change,
/// which closes this tap and opens a new one on the new device.
actor MicrophoneLevelTap {
    private var engine: AVAudioEngine?
    private var meter: DictationAudioLevelMeter?
    /// The newest request seen: a start or stop overtaken by a newer one on its way here does nothing.
    private var latest = 0

    /// Opens the input and feeds `meter`, unless request `number` is stale.
    func start(_ meter: DictationAudioLevelMeter, request number: Int) {
        guard number > latest else {
            meter.finish()
            return
        }
        latest = number
        close()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            meter.finish()
            return
        }
        // Real-time thread: the meter's RMS, a constant-time lock and a yield; nothing kept.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            meter.record(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            meter.finish()
            return
        }
        (self.engine, self.meter) = (engine, meter)
    }

    /// Closes the input, unless request `number` is stale.
    func stop(request number: Int) {
        guard number > latest else { return }
        latest = number
        close()
    }

    private func close() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        meter?.finish()
        (engine, meter) = (nil, nil)
    }
}

/// Numbers the main actor's opens and closes of the ``MicrophoneLevelTap`` in the order they were
/// asked, so the tap obeys the newest even when the hops reach it out of order.
@MainActor
final class MicrophoneLevelTapControl {
    private let tap = MicrophoneLevelTap()
    private var requests = 0

    /// Opens the tap into `meter`.
    func open(_ meter: DictationAudioLevelMeter) {
        requests += 1
        let (tap, number) = (tap, requests)
        Task { await tap.start(meter, request: number) }
    }

    /// Closes the tap.
    func close() {
        requests += 1
        let (tap, number) = (tap, requests)
        Task { await tap.stop(request: number) }
    }
}
