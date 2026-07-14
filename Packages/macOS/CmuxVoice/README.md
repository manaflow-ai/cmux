# CmuxVoice

On-device voice dictation for cmux: the dictation session state machine,
streaming transcript model, and the speech engines behind the
"Toggle Voice Dictation" shortcut.

## Design

- `DictationController` (`@MainActor @Observable`) owns the session
  lifecycle (`idle → requestingAuthorization → preparing → listening →
  stopping → idle`, with `failed` as a resting error state). The HUD
  observes `phase` and `transcript`.
- `DictationTranscript` folds `partial`/`final` transcription events into
  committed text plus a volatile tail, returning the exact delta to type
  for each finalized segment. Partials are HUD-only; a terminal cannot
  "un-type" a revised hypothesis.
- `SpeechTranscribing` is the engine seam. Production engines:
  - `SpeechAnalyzerDictationTranscriber` (macOS 26+): SpeechAnalyzer /
    SpeechTranscriber with managed `AssetInventory` model downloads.
  - `SFSpeechDictationTranscriber` (macOS 14–25): `SFSpeechRecognizer`
    with `requiresOnDeviceRecognition`; recognition cycles are chained so
    the caller sees one continuous stream.

  Both are on-device only; no audio or transcripts leave the machine.
- `DictationTextInserting` is the app-side insertion seam; the app pins
  the focused target (terminal PTY, native text responder, or editable
  web content) per session. `DictationInsertionRouteResolver` holds the
  pure routing priority.

## Testing

Everything deterministic is injectable: construct `DictationController`
with a fake `DictationAuthorizing`, a scripted `SpeechTranscribing`, and a
recording `DictationTextInserting`, then drive events. See
`Tests/CmuxVoiceTests/DictationControllerTests.swift`. The live
microphone/speech path cannot run in CI and is validated manually.

```bash
swift test
```
