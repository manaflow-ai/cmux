import MessagesLabHome

/// The message box's mic (`HomeVoiceDictation`), on while Debug Settings > Home > Mic button in the
/// message box is (the default). Off: the field shows Messages' drawn waveform, as before.
extension HomeNativeTranscriptView {
    func connectVoice() {
        voice.view = self
        followVoiceTunable()
    }

    private func followVoiceTunable() {
        withObservationTracking {
            let on = HomeTunables.voiceInput.value
            if !on { voice.cancelVoice() }
            transcript.voiceInput = on ? voice : nil
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followVoiceTunable() }
        }
    }
}
