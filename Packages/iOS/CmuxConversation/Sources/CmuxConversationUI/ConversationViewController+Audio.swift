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

/// Records an audio message in the composer: the field turns into a live
/// meter with a stop button, then a review strip (play, waveform, duration,
/// continue recording, send). "+" becomes a cancel button meanwhile.
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
    private var holding = false
    private let noticeLabel = UILabel()
    private var noticeTask: Task<Void, Never>?
    /// Paces the "Audio recording not available" notice (injected for tests).
    var clock: any Clock<Duration> = ContinuousClock()

    init(controller: ConversationViewController) {
        self.controller = controller
        field.onStop = { [weak self] in self?.stopToReview() }
        field.onSend = { [weak self] in self?.send() }
        field.onPlay = { [weak self] in self?.toggleReviewPlayback() }
        field.onContinue = { [weak self] in self?.continueRecording() }
    }

    var isActive: Bool { recorder != nil || startTask != nil }

    func installRecordButton() {
        guard let composer = controller?.composer else { return }
        let button = composer.micButton
        button.accessibilityLabel = String(localized: "conversation.audio.record", defaultValue: "Record Audio", bundle: .module)
        button.accessibilityIdentifier = "conversation.composer.record"
        button.addAction(UIAction { [weak self] _ in self?.start(holding: false) }, for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.25
        button.addGestureRecognizer(hold)
        noteConversationChanged()
    }

    func noteConversationChanged() {
        guard !showsRecordButton, let store = controller?.store, let meID = store.meID else { return }
        if store.messages.contains(where: { $0.senderID == meID && $0.audioAttachment != nil }) {
            setShowsRecordButton()
        }
    }

    private func setShowsRecordButton() {
        guard !showsRecordButton, let button = controller?.composer.micButton else { return }
        showsRecordButton = true
        button.setImage(UIImage(systemName: "waveform", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        button.isUserInteractionEnabled = true
        button.isAccessibilityElement = true
    }

    @objc private func held(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began:
            start(holding: true)
        case .ended, .cancelled, .failed:
            guard holding else { return }
            holding = false
            stopToReview()
        default:
            break
        }
    }

    // MARK: Flow

    func start(holding: Bool = false) {
        guard !isActive, let controller else { return }
        controller.dismissPhotoDrawer()
        // Messages: with no input device the field says so for ~3 s instead.
        if ConversationAudioRecorder.Input.fromEnvironment == .microphone, !AVAudioSession.sharedInstance().isInputAvailable {
            showUnavailableNotice()
            return
        }
        self.holding = holding
        let recorder = ConversationAudioRecorder()
        recorder.syntheticTranscript = Self.syntheticPhrases.randomElement()
        self.recorder = recorder
        show(in: controller)
        field.mode = .recording
        field.update(levels: [], time: 0)
        startTask = Task { [weak self] in
            do {
                try await recorder.start()
                guard let self, self.recorder === recorder else { return }
                self.startTask = nil
                self.startDisplayLink()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                // A hold released while permission was being granted.
                if holding, !self.holding { self.stopToReview() }
            } catch {
                guard let self else { return }
                self.startTask = nil
                self.dismiss()
                if (error as? ConversationBackendError)?.code == -10 {
                    self.controller?.presentMicrophoneDenied()
                } else {
                    self.showUnavailableNotice()
                }
            }
        }
    }

    func stopToReview() {
        guard let recorder, recorder.state == .recording else { return }
        recorder.pause()
        stopDisplayLink()
        guard recorder.duration > 0.25 else {
            cancel()
            return
        }
        field.mode = .review
        field.update(levels: recorder.levels, time: recorder.duration)
        field.setReview(playing: false, progress: 0, time: recorder.duration)
    }

    func continueRecording() {
        guard let recorder, recorder.state == .paused else { return }
        stopReviewPlayer()
        try? recorder.continueRecording()
        field.mode = .recording
        startDisplayLink()
    }

    func send() {
        guard let recorder, let controller else { return }
        stopReviewPlayer()
        guard let recorded = recorder.finish() else {
            dismiss()
            return
        }
        let replyTo = controller.replyTarget?.id
        dismiss()
        guard controller.store.sendAudio(data: recorded.data, info: recorded.info, replyToID: replyTo) != nil else { return }
        if controller.replyTarget != nil { controller.exitReplyMode() }
        setShowsRecordButton()
    }

    func cancel() {
        stopReviewPlayer()
        recorder?.cancel()
        dismiss()
    }

    private func toggleReviewPlayback() {
        guard let recorder else { return }
        if let reviewPlayer, reviewPlayer.isPlaying {
            reviewPlayer.pause()
            field.setReview(playing: false, progress: CGFloat(reviewPlayer.currentTime / max(0.01, reviewPlayer.duration)), time: reviewPlayer.currentTime)
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
        startDisplayLink()
    }

    private func stopReviewPlayer() {
        reviewPlayer?.stop()
        reviewPlayer = nil
    }

    /// Measured on iOS 26.3: 13 pt secondary text centered in the field, the
    /// placeholder hidden and "+" dimmed, for about 3 s.
    func showUnavailableNotice() {
        guard let composer = controller?.composer else { return }
        noticeTask?.cancel()
        noticeLabel.text = String(localized: "conversation.audio.unavailable", defaultValue: "Audio recording not available", bundle: .module)
        noticeLabel.font = .systemFont(ofSize: 13)
        noticeLabel.textColor = .secondaryLabel
        noticeLabel.textAlignment = .center
        noticeLabel.accessibilityIdentifier = "conversation.recording.unavailable"
        let field = composer.fieldGlass.contentView
        noticeLabel.frame = CGRect(x: 0, y: field.bounds.height - ConversationTheme.composerMinHeight, width: field.bounds.width, height: ConversationTheme.composerMinHeight)
        noticeLabel.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        field.addSubview(noticeLabel)
        noticeLabel.alpha = 0
        UIView.animate(withDuration: 0.2) {
            self.noticeLabel.alpha = 1
            composer.placeholder.alpha = 0
            composer.textView.alpha = 0
            composer.plusButton.alpha = 0.3
        }
        UIAccessibility.post(notification: .announcement, argument: noticeLabel.text)
        let clock = clock
        noticeTask = Task { [weak self] in
            try? await clock.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            UIView.animate(withDuration: 0.2) {
                self.noticeLabel.alpha = 0
                composer.placeholder.alpha = 1
                composer.textView.alpha = 1
                composer.plusButton.alpha = 1
            } completion: { _ in
                self.noticeLabel.removeFromSuperview()
            }
        }
    }

    // MARK: Field

    private func show(in controller: ConversationViewController) {
        let composer = controller.composer
        field.frame = composer.fieldGlass.contentView.bounds
        field.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        composer.fieldGlass.contentView.addSubview(field)
        field.alpha = 0
        UIView.animate(withDuration: 0.2) {
            self.field.alpha = 1
            composer.textView.alpha = 0
            composer.placeholder.alpha = 0
            composer.sendButton.isHidden = true
            composer.micButton.alpha = 0
        }
        composer.textView.resignFirstResponder()
        setPlusGlyph("xmark", in: composer)
        composer.plusButton.accessibilityLabel = String(localized: "conversation.audio.cancel", defaultValue: "Cancel Recording", bundle: .module)
    }

    private func dismiss() {
        stopDisplayLink()
        startTask?.cancel()
        startTask = nil
        recorder = nil
        holding = false
        guard let composer = controller?.composer else { return }
        setPlusGlyph("plus", in: composer)
        composer.plusButton.accessibilityLabel = String(localized: "conversation.composer.plus", defaultValue: "Apps", bundle: .module)
        UIView.animate(withDuration: 0.2) {
            self.field.alpha = 0
            composer.textView.alpha = 1
            composer.placeholder.alpha = 1
            composer.micButton.alpha = composer.hasContent ? 0 : 1
        } completion: { _ in
            composer.sendButton.isHidden = false
            if self.recorder == nil { self.field.removeFromSuperview() }
        }
    }

    private func setPlusGlyph(_ symbol: String, in composer: ConversationComposerView) {
        let image = UIImage(systemName: symbol, withConfiguration: ConversationComposerView.plusSymbolConfiguration)
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
            field.setReview(playing: playing, progress: playing ? CGFloat(reviewPlayer.currentTime / max(0.01, reviewPlayer.duration)) : 0, time: time)
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

/// The composer field while recording (live meter, timer, stop) and while
/// reviewing (play, waveform, duration, continue recording, send).
final class AudioRecordingFieldView: UIView {
    enum Mode { case recording, review }

    var mode: Mode = .recording { didSet { applyMode() } }
    var onStop: (() -> Void)?
    var onSend: (() -> Void)?
    var onPlay: (() -> Void)?
    var onContinue: (() -> Void)?

    private let timeLabel = UILabel()
    private let waveform = AudioWaveformView()
    private let stopButton = UIButton(type: .custom)
    private let stopSquare = UIView()
    private let playButton = UIButton(type: .custom)
    private let continueButton = UIButton(type: .custom)
    private let sendButton = UIButton(type: .custom)
    private let sendSize = ComposerBarGeometry.sendSize

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "conversation.composer.recording"
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .regular)
        timeLabel.textColor = .label
        timeLabel.accessibilityIdentifier = "conversation.recording.time"
        addSubview(timeLabel)
        addSubview(waveform)

        stopButton.backgroundColor = .systemRed
        stopButton.layer.cornerRadius = 14
        stopButton.accessibilityLabel = String(localized: "conversation.audio.stop", defaultValue: "Stop Recording", bundle: .module)
        stopButton.accessibilityIdentifier = "conversation.recording.stop"
        stopSquare.backgroundColor = .white
        stopSquare.layer.cornerRadius = 2.5
        stopSquare.isUserInteractionEnabled = false
        stopButton.addSubview(stopSquare)
        stopButton.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .touchUpInside)
        addSubview(stopButton)

        playButton.tintColor = .systemBlue
        playButton.accessibilityIdentifier = "conversation.recording.play"
        playButton.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .touchUpInside)
        addSubview(playButton)

        continueButton.setImage(UIImage(systemName: "record.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)), for: .normal)
        continueButton.tintColor = .systemRed
        continueButton.accessibilityLabel = String(localized: "conversation.audio.continue", defaultValue: "Continue Recording", bundle: .module)
        continueButton.accessibilityIdentifier = "conversation.recording.continue"
        continueButton.addAction(UIAction { [weak self] _ in self?.onContinue?() }, for: .touchUpInside)
        addSubview(continueButton)

        sendButton.backgroundColor = ConversationComposerView.sendBlue
        sendButton.setImage(UIImage(systemName: "arrow.up", withConfiguration: ConversationComposerView.sendSymbolConfiguration), for: .normal)
        sendButton.tintColor = .white
        sendButton.layer.cornerRadius = sendSize.height / 2
        sendButton.layer.cornerCurve = .continuous
        sendButton.accessibilityLabel = String(localized: "conversation.composer.send", defaultValue: "Send", bundle: .module)
        sendButton.accessibilityIdentifier = "conversation.recording.send"
        sendButton.addAction(UIAction { [weak self] _ in self?.onSend?() }, for: .touchUpInside)
        addSubview(sendButton)
        applyMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rowHeight = ConversationTheme.composerMinHeight
        let rowY = bounds.height - rowHeight
        let midY = rowY + rowHeight / 2
        let trailingCenterX = bounds.width - ComposerBarGeometry.sendTrailingInset - sendSize.width / 2
        sendButton.bounds = CGRect(origin: .zero, size: sendSize)
        sendButton.center = CGPoint(x: trailingCenterX, y: midY)
        stopButton.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        stopButton.center = CGPoint(x: trailingCenterX + 2, y: midY)
        stopSquare.frame = CGRect(x: 9, y: 9, width: 10, height: 10)
        let barsHeight = AudioBubbleLayout.maxBarHeight + 4
        switch mode {
        case .recording:
            timeLabel.frame = CGRect(x: 14.5, y: rowY, width: 50, height: rowHeight)
            let waveX: CGFloat = 64
            waveform.frame = CGRect(x: waveX, y: midY - barsHeight / 2, width: stopButton.frame.minX - 10 - waveX, height: barsHeight)
        case .review:
            playButton.frame = CGRect(x: 6, y: midY - 15, width: 30, height: 30)
            continueButton.frame = CGRect(x: sendButton.frame.minX - 38, y: midY - 15, width: 32, height: 30)
            timeLabel.frame = CGRect(x: continueButton.frame.minX - 46, y: rowY, width: 44, height: rowHeight)
            let waveX = playButton.frame.maxX + 6
            waveform.frame = CGRect(x: waveX, y: midY - barsHeight / 2, width: max(0, timeLabel.frame.minX - 6 - waveX), height: barsHeight)
        }
    }

    private func applyMode() {
        let recording = mode == .recording
        stopButton.isHidden = !recording
        playButton.isHidden = recording
        continueButton.isHidden = recording
        sendButton.isHidden = recording
        waveform.alignsTrailing = recording
        waveform.playedColor = recording ? .systemRed : .systemBlue
        waveform.unplayedColor = UIColor.secondaryLabel.withAlphaComponent(0.6)
        timeLabel.textAlignment = recording ? .left : .right
        timeLabel.textColor = recording ? .label : .secondaryLabel
        setNeedsLayout()
    }

    func update(levels: [Float], time: TimeInterval) {
        waveform.levels = levels
        timeLabel.text = AudioMessageStrings.clock(time)
    }

    func setReview(playing: Bool, progress: CGFloat, time: TimeInterval) {
        waveform.progress = progress
        timeLabel.text = AudioMessageStrings.clock(time)
        let symbol = playing ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)), for: .normal)
        playButton.accessibilityLabel = playing ? AudioMessageStrings.pause : AudioMessageStrings.play
    }
}
#endif
