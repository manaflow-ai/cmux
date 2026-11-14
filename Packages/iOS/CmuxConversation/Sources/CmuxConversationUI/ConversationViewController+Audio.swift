#if canImport(UIKit)
import AVFoundation
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

extension ConversationViewController: AudioMessageCellDelegate {
    func keepAudio(messageID: String) {
        store.keepAudio(messageID: messageID)
    }

    /// Wires playback (auto-advance, listened reports) and the composer's
    /// record button. Called once from `viewDidLoad`.
    func installAudio() {
        audioPlayer.nextMessage = { [weak self] finishedID in
            self?.audioMessage(after: finishedID)
        }
        audioPlayer.onFinished = { [weak self] messageID in
            self?.store.audioPlayed(messageID: messageID)
        }
        audioComposer.installRecordButton()
        store.addObserver { [weak self] _ in self?.audioComposer.noteConversationChanged() }
    }

    /// Messages plays the next recording when it directly follows the one
    /// that finished and both came from someone else.
    func audioMessage(after messageID: String) -> ConversationMessage? {
        guard let finished = store.message(id: messageID), finished.senderID != store.meID,
              let index = store.messages.firstIndex(where: { $0.id == messageID }),
              index + 1 < store.messages.count else { return nil }
        let next = store.messages[index + 1]
        guard next.senderID != store.meID, next.audioAttachment != nil else { return nil }
        return next
    }

    func presentMicrophoneDenied() {
        let alert = UIAlertController(
            title: String(localized: "conversation.audio.micDenied.title", defaultValue: "Microphone Access Is Off", bundle: .module),
            message: String(localized: "conversation.audio.micDenied.message", defaultValue: "To record audio messages, allow microphone access in Settings.", bundle: .module),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "conversation.audio.ok", defaultValue: "OK", bundle: .module), style: .default))
        present(alert, animated: true)
    }
}

/// Records an audio message in the composer the way Messages does on iOS 26
/// (`ComposerAudioLayout` has the measured frames):
/// - a tap on the record glyph only says "Tap and hold to record and send
///   audio" in the field for 2 s;
/// - a hold starts recording: the field lifts, a solid red stop replaces the
///   glyph, red silence dots fill the field and the timer runs;
/// - lifting the finger keeps recording: the field swallows the "+" and grows
///   taller, and the stop dims;
/// - stop opens the review: an "x" in the "+"'s place, then play, the
///   waveform, a "+ 0:03" pill that records more, and send.
/// VoiceOver has no hold: activating the button records straight away.
@MainActor
final class ConversationAudioComposer {
    private weak var controller: ConversationViewController?
    private var recorder: ConversationAudioRecorder?
    private let field = AudioRecordingFieldView()
    private var displayLink: CADisplayLink?
    private var reviewPlayer: AVAudioPlayer?
    private var startTask: Task<Void, Never>?
    /// Messages shows the Record Audio button in the field once audio was
    /// used in the conversation.
    private(set) var showsRecordButton = false
    /// Tap, hold, lock, review: Messages' record flow.
    private(set) var flow = ComposerAudioFlow()
    private let noticeLabel = UILabel()
    private var noticeTask: Task<Void, Never>?
    /// Paces the notices (injected for tests).
    var clock: any Clock<Duration> = ContinuousClock()
    /// A press this long records; a shorter tap shows the hold hint.
    static let holdDuration: TimeInterval = 0.2
    /// How long Messages leaves "Tap and hold to record and send audio" up.
    static let hintDuration: Duration = .seconds(2)

    init(controller: ConversationViewController) {
        self.controller = controller
        field.onStop = { [weak self] in self?.stopToReview() }
        field.onSend = { [weak self] in self?.send() }
        field.onPlay = { [weak self] in self?.toggleReviewPlayback() }
        field.onContinue = { [weak self] in self?.continueRecording() }
    }

    var isActive: Bool { flow.isActive || recorder != nil || startTask != nil }
    /// The stage the composer shows, nil while typing.
    var stage: ComposerAudioLayout.Stage? { controller?.composer.audioStage }

    func installRecordButton() {
        guard let composer = controller?.composer else { return }
        let button = composer.micButton
        button.accessibilityLabel = String(localized: "conversation.audio.record", defaultValue: "Record Audio", bundle: .module)
        button.accessibilityHint = Self.holdHint
        button.accessibilityIdentifier = "conversation.composer.record"
        button.addAction(UIAction { [weak self] _ in self?.recordButtonTapped() }, for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = Self.holdDuration
        button.addGestureRecognizer(hold)
        noteConversationChanged()
    }

    static var holdHint: String {
        String(localized: "conversation.audio.holdHint", defaultValue: "Tap and hold to record and send audio", bundle: .module)
    }

    func noteConversationChanged() {
        guard !showsRecordButton, let store = controller?.store, let meID = store.meID else { return }
        // A synthetic or file input (UI tests, demos) stands in for audio already sent.
        let sentAudio = ConversationAudioRecorder.Input.fromEnvironment != .microphone
            || store.messages.contains(where: { $0.senderID == meID && $0.audioAttachment != nil })
        if ComposerBarGeometry.showsRecordGlyph(iOS27: ConversationComposerView.isIOS27, sentAudio: sentAudio) {
            setShowsRecordButton()
        }
    }

    private func setShowsRecordButton() {
        guard !showsRecordButton, let button = controller?.composer.micButton else { return }
        showsRecordButton = true
        controller?.composer.showRecordGlyph()
        button.isUserInteractionEnabled = true
        button.isAccessibilityElement = true
    }

    /// A tap too short to record: Messages answers with the hold hint.
    /// VoiceOver cannot hold, so there the activation records (stop ends it).
    func recordButtonTapped() {
        run(.tap(voiceOver: UIAccessibility.isVoiceOverRunning))
    }

    @objc private func held(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began:
            run(.holdBegan)
        case .ended, .cancelled, .failed:
            run(.holdEnded)
        default:
            break
        }
    }

    // MARK: Flow

    /// Feeds `event` to the flow, carries out its effects, then moves the
    /// row to the flow's stage.
    func run(_ event: ComposerAudioFlow.Event) {
        let before = flow.stage
        let effects = flow.handle(event)
        var resumeFailed = false
        for effect in effects {
            switch effect {
            case .showHoldHint: showNotice(Self.holdHint, style: .hint)
            case .startRecording: beginRecording()
            case .pauseRecording:
                recorder?.pause()
                stopDisplayLink()
            case .resumeRecording:
                stopReviewPlayer()
                do {
                    try recorder?.continueRecording()
                    startDisplayLink()
                } catch {
                    resumeFailed = true
                }
            case .discard:
                stopReviewPlayer()
                recorder?.cancel()
                dismiss()
            case .sendRecording: sendRecording()
            }
        }
        if resumeFailed {
            // The review stays up (stop is unreachable from a recording that never started).
            flow.handle(.resumeFailed)
            showNotice(Self.unavailableText, style: .unavailable)
            return
        }
        guard let stage = flow.stage, stage != before else { return }
        if stage == .review, let recorder {
            field.update(levels: recorder.levels, time: recorder.duration)
            field.setReview(playing: false, progress: 0, time: recorder.duration, duration: recorder.duration)
        }
        if before == nil {
            guard let controller else { return }
            show(in: controller, stage: stage)
        } else {
            setStage(stage)
        }
    }

    /// Starts the recorder for the flow's new stage.
    private func beginRecording() {
        guard let controller else { return }
        controller.dismissPhotoDrawer()
        // Messages: with no input device the field says so for ~3 s instead.
        if ConversationAudioRecorder.Input.fromEnvironment == .microphone, !AVAudioSession.sharedInstance().isInputAvailable {
            flow = ComposerAudioFlow()
            showNotice(Self.unavailableText, style: .unavailable)
            return
        }
        hideNotice(animated: false)
        let recorder = ConversationAudioRecorder()
        recorder.syntheticTranscript = Self.syntheticPhrases.randomElement()
        self.recorder = recorder
        field.update(levels: [], time: 0)
        startTask = Task { [weak self] in
            do {
                try await recorder.start()
                guard let self, self.recorder === recorder else {
                    // Discarded while starting: release the microphone and its file.
                    recorder.cancel()
                    return
                }
                self.startTask = nil
                self.startDisplayLink()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self.run(.recorderStarted)
            } catch {
                guard let self, self.recorder === recorder, !(error is CancellationError) else { return }
                self.startTask = nil
                self.run(.cancel)
                if (error as? ConversationBackendError)?.code == -10 {
                    self.controller?.presentMicrophoneDenied()
                } else {
                    self.showNotice(Self.unavailableText, style: .unavailable)
                }
            }
        }
    }

    static var unavailableText: String {
        String(localized: "conversation.audio.unavailable", defaultValue: "Audio recording not available", bundle: .module)
    }

    func stopToReview() {
        guard let recorder, recorder.state == .recording else { return }
        // Messages throws away a recording of a quarter second or less.
        run(.stop(longEnough: recorder.duration > 0.25))
    }

    func continueRecording() {
        guard recorder?.state == .paused else { return }
        run(.continueRecording)
    }

    func send() {
        run(.send)
    }

    private func sendRecording() {
        guard let recorder, let controller else { return dismiss() }
        stopReviewPlayer()
        guard let recorded = recorder.finish() else { return dismiss() }
        let replyTo = controller.replyTarget?.id
        dismiss()
        // A reply stays in its open thread, as a typed one does.
        guard controller.store.sendAudio(data: recorded.data, info: recorded.info, replyToID: replyTo) != nil else { return }
        setShowsRecordButton()
    }

    func cancel() {
        run(.cancel)
    }

    private func toggleReviewPlayback() {
        guard let recorder else { return }
        if let reviewPlayer, reviewPlayer.isPlaying {
            reviewPlayer.pause()
            field.setReview(playing: false, progress: CGFloat(reviewPlayer.currentTime / max(0.01, reviewPlayer.duration)), time: reviewPlayer.currentTime, duration: recorder.duration)
            stopDisplayLink()
            return
        }
        if reviewPlayer == nil {
            reviewPlayer = try? AVAudioPlayer(data: recorder.reviewData)
            reviewPlayer?.prepareToPlay()
        }
        guard let reviewPlayer else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        reviewPlayer.play()
        field.setReview(playing: true, progress: 0, time: 0, duration: recorder.duration)
        startDisplayLink()
    }

    private func stopReviewPlayer() {
        reviewPlayer?.stop()
        reviewPlayer = nil
    }

    // MARK: Notices

    enum NoticeStyle {
        /// "Tap and hold…": 13 pt secondary text where the placeholder starts.
        case hint
        /// "Audio recording not available": centered, with the "+" dimmed.
        case unavailable
    }

    /// Messages swaps the placeholder for a short notice: the hold hint
    /// (measured on iOS 26: 13 pt secondaryLabel at the placeholder's x,
    /// about 2 s), or "Audio recording not available" (centered, "+"
    /// dimmed, about 3 s).
    func showNotice(_ text: String, style: NoticeStyle) {
        guard let composer = controller?.composer else { return }
        noticeTask?.cancel()
        noticeLabel.text = text
        noticeLabel.font = .systemFont(ofSize: 13)
        noticeLabel.textColor = .secondaryLabel
        noticeLabel.textAlignment = style == .hint ? .natural : .center
        noticeLabel.accessibilityIdentifier = style == .hint ? "conversation.recording.holdHint" : "conversation.recording.unavailable"
        let field = composer.fieldGlass.contentView
        let inset = style == .hint ? ComposerBarGeometry.textLeadingInset : 0
        let trailing = style == .hint ? 44 : 0
        noticeLabel.frame = CGRect(x: inset, y: field.bounds.height - ConversationTheme.composerMinHeight, width: field.bounds.width - inset - CGFloat(trailing), height: ConversationTheme.composerMinHeight)
        noticeLabel.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        if noticeLabel.superview !== field { field.addSubview(noticeLabel) }
        noticeLabel.alpha = 0
        let dimsPlus = style == .unavailable
        UIView.animate(withDuration: 0.2) {
            self.noticeLabel.alpha = 1
            composer.placeholder.alpha = 0
            // The hint takes only the placeholder's place: text typed meanwhile stays visible.
            if dimsPlus {
                composer.textView.alpha = 0
                composer.plusButton.alpha = 0.3
            }
        }
        UIAccessibility.post(notification: .announcement, argument: text)
        let clock = clock
        let duration = style == .hint ? Self.hintDuration : .seconds(3)
        noticeTask = Task { [weak self] in
            try? await clock.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.hideNotice(animated: true)
        }
    }

    private func hideNotice(animated: Bool) {
        guard noticeLabel.superview != nil, let composer = controller?.composer else { return }
        noticeTask?.cancel()
        noticeTask = nil
        let restore = {
            self.noticeLabel.alpha = 0
            if !self.isActive {
                composer.placeholder.alpha = 1
                composer.textView.alpha = 1
            }
            composer.plusButton.alpha = 1
        }
        guard animated else {
            restore()
            noticeLabel.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: 0.2, animations: restore) { _ in
            if self.noticeLabel.alpha == 0 { self.noticeLabel.removeFromSuperview() }
        }
    }

    // MARK: Field

    private func show(in controller: ConversationViewController, stage: ComposerAudioLayout.Stage) {
        let composer = controller.composer
        composer.textView.resignFirstResponder()
        field.frame = composer.fieldGlass.contentView.bounds
        field.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        composer.fieldGlass.contentView.addSubview(field)
        composer.audioFieldView = field
        field.alpha = 0
        // The glyph turns into the stop button where it stands.
        field.prepareEntrance(from: composer.micButton.convert(composer.micButton.bounds, to: composer.fieldGlass.contentView))
        setStage(stage) {
            self.field.alpha = 1
            composer.textView.alpha = 0
            composer.placeholder.alpha = 0
            composer.sendButton.isHidden = true
            composer.micButton.alpha = 0
        }
    }

    /// Moves the row to `stage` on Messages' springs: the lift on press is
    /// quick, the swallow of the "+" and the return to review settle with a
    /// little overshoot.
    private func setStage(_ stage: ComposerAudioLayout.Stage, alongside: (() -> Void)? = nil) {
        guard let composer = controller?.composer else { return }
        let previous = composer.audioStage
        composer.audioStage = stage
        setPlusGlyph(stage == .review ? "xmark" : "plus", in: composer)
        // Only the review's x cancels; held, the + is still the apps button under the finger's row.
        composer.plusButton.accessibilityLabel = stage == .review
            ? String(localized: "conversation.audio.cancel", defaultValue: "Cancel Recording", bundle: .module)
            : String(localized: "conversation.composer.plus", defaultValue: "Apps", bundle: .module)
        let changes = {
            composer.layoutIfNeeded()
            alongside?()
        }
        let (duration, damping): (TimeInterval, CGFloat) = switch (previous, stage) {
        case (nil, _): (0.3, 0.82)
        case (_, .recording): (0.42, 0.74)
        case (_, .review): (0.5, 0.72)
        default: (0.3, 0.82)
        }
        animate(duration: duration, damping: damping, changes)
    }

    private func animate(duration: TimeInterval, damping: CGFloat, _ changes: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
        // Reduce Motion: the same change as a short crossfade, no springing.
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes, completion: completion)
        } else {
            UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: damping, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes, completion: completion)
        }
    }

    private func dismiss() {
        stopDisplayLink()
        startTask?.cancel()
        startTask = nil
        recorder = nil
        flow = ComposerAudioFlow()
        guard let composer = controller?.composer else { return }
        composer.audioStage = nil
        setPlusGlyph("plus", in: composer)
        composer.plusButton.accessibilityLabel = String(localized: "conversation.composer.plus", defaultValue: "Apps", bundle: .module)
        animate(duration: 0.38, damping: 0.86, {
            composer.layoutIfNeeded()
            self.field.alpha = 0
            composer.textView.alpha = 1
            composer.placeholder.alpha = 1
            composer.micButton.alpha = composer.hasContent ? 0 : 1
        }, completion: { _ in
            // A new recording began during this spring: leave its field alone.
            guard composer.audioStage == nil else { return }
            composer.sendButton.isHidden = false
            if self.recorder == nil {
                self.field.removeFromSuperview()
                composer.audioFieldView = nil
            }
        })
    }

    private func setPlusGlyph(_ symbol: String, in composer: ConversationComposerView) {
        let image = UIImage(systemName: symbol, withConfiguration: ConversationComposerView.plusSymbolConfiguration)
        guard composer.plusButton.image(for: .normal) != image else { return }
        UIView.transition(with: composer.plusButton, duration: 0.2, options: .transitionCrossDissolve) {
            composer.plusButton.setImage(image, for: .normal)
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frameTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func frameTick() {
        guard let recorder else {
            stopDisplayLink()
            return
        }
        switch recorder.state {
        case .recording:
            recorder.tick()
            field.update(levels: recorder.levels, time: recorder.duration)
        case .paused:
            guard let reviewPlayer else { return }
            let playing = reviewPlayer.isPlaying
            let time = playing ? reviewPlayer.currentTime : recorder.duration
            field.setReview(playing: playing, progress: playing ? CGFloat(reviewPlayer.currentTime / max(0.01, reviewPlayer.duration)) : 0, time: time, duration: recorder.duration)
            if !playing {
                stopReviewPlayer()
                stopDisplayLink()
            }
        case .idle:
            stopDisplayLink()
        }
    }

    /// What a synthetic (no microphone) recording "says".
    static let syntheticPhrases = [
        "Hey, just checking in, call me when you're free.",
        "On my way, see you in ten.",
        "I pushed the fix, can you try the new build?",
        "Sounds good to me.",
    ]
}

/// Messages' recording reds, read from iOS 26 in dark mode (light mode
/// uses systemRed's own light values at the same strengths).
@MainActor
enum AudioRecordingInk {
    /// The timer and the bars just recorded (255,80,91).
    static let live = UIColor.resolving { $0.userInterfaceStyle == .dark ? UIColor(red: 1, green: 80 / 255, blue: 91 / 255, alpha: 1) : .systemRed }
    /// The silence dots ahead of the recording (184,55,57 on the glass).
    static let dots = UIColor.resolving { $0.userInterfaceStyle == .dark ? UIColor(red: 184 / 255, green: 55 / 255, blue: 59 / 255, alpha: 1) : UIColor.systemRed.withAlphaComponent(0.55) }
    /// Held: a solid stop (193,60,63) with a bright square (255,74,81).
    static let heldStop = UIColor.resolving { $0.userInterfaceStyle == .dark ? UIColor(red: 193 / 255, green: 60 / 255, blue: 63 / 255, alpha: 1) : .systemRed }
    static let heldSquare = UIColor.resolving { $0.userInterfaceStyle == .dark ? UIColor(red: 1, green: 74 / 255, blue: 81 / 255, alpha: 1) : .white }
    /// Recording, finger up: the stop dims to (100,65,66) with a (178,67,69) square.
    static let lockedStop = UIColor.resolving { $0.userInterfaceStyle == .dark ? UIColor(red: 100 / 255, green: 65 / 255, blue: 66 / 255, alpha: 1) : UIColor.systemRed.withAlphaComponent(0.22) }
    static let lockedSquare = UIColor.resolving { $0.userInterfaceStyle == .dark ? UIColor(red: 178 / 255, green: 67 / 255, blue: 69 / 255, alpha: 1) : .systemRed }
}

/// The composer field while recording (silence dots, live bars, timer,
/// stop) and while reviewing (play, waveform, "+ 0:03", send), laid out
/// by the composer from `ComposerAudioLayout`.
final class AudioRecordingFieldView: UIView {
    var onStop: (() -> Void)?
    var onSend: (() -> Void)?
    var onPlay: (() -> Void)?
    var onContinue: (() -> Void)?

    private(set) var stage: ComposerAudioLayout.Stage = .holding
    private let timeLabel = UILabel()
    let waveform = ComposerAudioWaveformView()
    let stopButton = UIButton(type: .custom)
    private let stopSquare = UIView()
    let playButton = UIButton(type: .custom)
    let continueButton = UIButton(type: .custom)
    let sendButton = UIButton(type: .custom)
    private var time: TimeInterval = 0
    private var duration: TimeInterval = 0
    private var playing = false
    static let timerFont = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "conversation.composer.recording"
        timeLabel.font = Self.timerFont
        timeLabel.textAlignment = .right
        timeLabel.accessibilityIdentifier = "conversation.recording.time"
        addSubview(waveform)
        addSubview(timeLabel)

        stopButton.layer.cornerCurve = .circular
        stopButton.accessibilityLabel = String(localized: "conversation.audio.stop", defaultValue: "Stop Recording", bundle: .module)
        stopButton.accessibilityIdentifier = "conversation.recording.stop"
        stopSquare.layer.cornerRadius = ComposerAudioLayout.stopSquareCornerRadius
        stopSquare.layer.cornerCurve = .continuous
        stopSquare.isUserInteractionEnabled = false
        stopButton.addSubview(stopSquare)
        stopButton.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .touchUpInside)
        addSubview(stopButton)

        playButton.backgroundColor = .tertiarySystemFill
        playButton.tintColor = .label
        playButton.accessibilityIdentifier = "conversation.recording.play"
        playButton.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .touchUpInside)
        addSubview(playButton)

        continueButton.backgroundColor = .quaternarySystemFill
        continueButton.layer.cornerCurve = .continuous
        continueButton.accessibilityLabel = String(localized: "conversation.audio.continue", defaultValue: "Continue Recording", bundle: .module)
        continueButton.accessibilityIdentifier = "conversation.recording.continue"
        continueButton.addAction(UIAction { [weak self] _ in self?.onContinue?() }, for: .touchUpInside)
        addSubview(continueButton)

        sendButton.backgroundColor = ConversationComposerView.sendBlue
        sendButton.setImage(UIImage(systemName: "arrow.up", withConfiguration: ConversationComposerView.sendSymbolConfiguration), for: .normal)
        sendButton.tintColor = .white
        sendButton.layer.cornerRadius = ComposerBarGeometry.sendSize.height / 2
        sendButton.layer.cornerCurve = .continuous
        sendButton.accessibilityLabel = String(localized: "conversation.composer.send", defaultValue: "Send", bundle: .module)
        sendButton.accessibilityIdentifier = "conversation.recording.send"
        sendButton.addAction(UIAction { [weak self] _ in self?.onSend?() }, for: .touchUpInside)
        addSubview(sendButton)
        setReview(playing: false, progress: 0, time: 0, duration: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Starts the stop button on the record glyph, so the first stage's
    /// spring grows it out of the glyph (Messages: the glyph swells red).
    func prepareEntrance(from glyph: CGRect) {
        UIView.performWithoutAnimation {
            stopButton.bounds = CGRect(origin: .zero, size: glyph.size)
            stopButton.center = CGPoint(x: glyph.midX, y: glyph.midY)
            stopButton.layer.cornerRadius = glyph.height / 2
            stopButton.backgroundColor = AudioRecordingInk.heldStop
            stopSquare.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
            stopSquare.center = CGPoint(x: glyph.width / 2, y: glyph.height / 2)
        }
    }

    /// Lays the field out for `stage` (called inside the composer's layout,
    /// so it rides the stage's spring).
    func apply(_ layout: ComposerAudioLayout, stage: ComposerAudioLayout.Stage) {
        self.stage = stage
        let recording = stage != .review
        stopButton.bounds = CGRect(origin: .zero, size: layout.stop.size)
        stopButton.center = CGPoint(x: layout.stop.midX, y: layout.stop.midY)
        stopButton.layer.cornerRadius = layout.stop.height / 2
        stopSquare.bounds = CGRect(origin: .zero, size: layout.stopSquare.size)
        stopSquare.center = CGPoint(x: layout.stopSquare.midX, y: layout.stopSquare.midY)
        stopButton.backgroundColor = stage == .holding ? AudioRecordingInk.heldStop : AudioRecordingInk.lockedStop
        stopSquare.backgroundColor = stage == .holding ? AudioRecordingInk.heldSquare : AudioRecordingInk.lockedSquare
        let timerWidth = ComposerAudioLayout.timerWidth + 8
        timeLabel.frame = CGRect(x: layout.timerTrailing - timerWidth, y: layout.midY - 10, width: timerWidth, height: 20)
        waveform.frame = layout.waveform
        waveform.mode = recording ? .live : .review
        // Bounds and center: play and send carry a scale while they grow in,
        // and a frame set under a transform is scaled by it.
        for (view, rect) in [(playButton, layout.play), (continueButton, layout.pill), (sendButton, layout.send)] as [(UIView, CGRect)] {
            view.bounds = CGRect(origin: .zero, size: rect.size)
            view.center = CGPoint(x: rect.midX, y: rect.midY)
        }
        playButton.layer.cornerRadius = layout.play.height / 2
        continueButton.layer.cornerRadius = layout.pill.height / 2
        stopButton.alpha = recording ? 1 : 0
        timeLabel.alpha = recording ? 1 : 0
        for view in [playButton, continueButton, sendButton] as [UIView] {
            view.alpha = recording ? 0 : 1
            view.isUserInteractionEnabled = !recording
        }
        stopButton.isUserInteractionEnabled = recording
        // Review: the controls grow in from the field's middle as it settles.
        let grow = recording ? CGAffineTransform(scaleX: 0.5, y: 0.5) : .identity
        playButton.transform = grow
        sendButton.transform = grow
        refreshTimer()
    }

    func update(levels: [Float], time: TimeInterval) {
        waveform.levels = levels
        self.time = time
        refreshTimer()
    }

    /// Review: play or pause, how far playback got, and the time. While it
    /// plays the pill gives way to the elapsed time ("0:01"); at rest it
    /// offers "+ 0:03" to record more.
    func setReview(playing: Bool, progress: CGFloat, time: TimeInterval, duration: TimeInterval) {
        self.playing = playing
        self.duration = duration
        waveform.progress = progress
        let symbol = playing ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .heavy)), for: .normal)
        playButton.accessibilityLabel = playing ? AudioMessageStrings.pause : AudioMessageStrings.play
        let title = playing ? AudioMessageStrings.clock(time) : "+ " + AudioMessageStrings.clock(duration)
        let attributed = NSAttributedString(string: title, attributes: [.font: Self.timerFont, .foregroundColor: UIColor.label])
        // While playing the time is plain text in full ink, not a dimmed button.
        continueButton.setAttributedTitle(attributed, for: .normal)
        continueButton.setAttributedTitle(attributed, for: .disabled)
        continueButton.backgroundColor = playing ? .clear : .quaternarySystemFill
        continueButton.isEnabled = !playing
        continueButton.accessibilityValue = AudioMessageStrings.clock(duration)
    }

    private func refreshTimer() {
        timeLabel.text = AudioMessageStrings.clock(time)
        timeLabel.textColor = AudioRecordingInk.live
    }
}

/// The recording field's waveform. Live: silence dots fill the width and
/// the newest levels enter at the trailing end in the live red, scrolling
/// left. Review: the whole recording resampled across the width, the played
/// part in label ink.
final class ComposerAudioWaveformView: UIView {
    enum Mode { case live, review }
    var mode: Mode = .live { didSet { if oldValue != mode { setNeedsDisplay() } } }
    var levels: [Float] = [] { didSet { setNeedsDisplay() } }
    var progress: CGFloat = 0 { didSet { if oldValue != progress { setNeedsDisplay() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Bar heights and whether each is lit, leading to trailing.
    static func bars(levels: [Float], count: Int, mode: Mode) -> [(level: Float, lit: Bool)] {
        guard count > 0 else { return [] }
        switch mode {
        case .live:
            let recent = Array(levels.suffix(count))
            let pad = count - recent.count
            return (0..<count).map { index in index < pad ? (level: Float(0), lit: false) : (level: recent[index - pad], lit: true) }
        case .review:
            let shown = levels.isEmpty ? [Float](repeating: 0, count: count) : ConversationAudioInfo.resample(levels, count: count)
            return shown.map { (level: $0, lit: false) }
        }
    }

    override func draw(_ rect: CGRect) {
        let count = ComposerAudioLayout.barCount(width: bounds.width)
        let bars = Self.bars(levels: levels, count: count, mode: mode)
        let pitch = ComposerAudioLayout.barPitch
        let width = ComposerAudioLayout.barWidth
        let playedEdge = progress * bounds.width
        let unplayed = UIColor.tertiaryLabel
        for (index, bar) in bars.enumerated() {
            let height = ComposerAudioLayout.barHeight(level: bar.level, band: bounds.height)
            let x = CGFloat(index) * pitch
            let color: UIColor = switch mode {
            case .live: bar.lit ? AudioRecordingInk.live : AudioRecordingInk.dots
            case .review: x + width / 2 <= playedEdge ? .label : unplayed
            }
            color.setFill()
            UIBezierPath(roundedRect: CGRect(x: x, y: (bounds.height - height) / 2, width: width, height: height), cornerRadius: width / 2).fill()
        }
    }
}
#endif
