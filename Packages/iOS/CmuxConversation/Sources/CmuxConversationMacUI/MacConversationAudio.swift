#if os(macOS)
import AppKit
import AVFoundation
import CmuxConversationCore

enum MacAudioStrings {
    static var audioMessage: String { String(localized: "conversation.audio.message", defaultValue: "Audio Message", bundle: .module) }
    static var play: String { String(localized: "conversation.audio.play", defaultValue: "Play", bundle: .module) }
    static var pause: String { String(localized: "conversation.audio.pause", defaultValue: "Pause", bundle: .module) }
    static var keep: String { String(localized: "conversation.audio.keep", defaultValue: "Keep", bundle: .module) }
    static var kept: String { String(localized: "conversation.audio.kept", defaultValue: "Kept", bundle: .module) }

    static func expiresIn(minutes: Int) -> String {
        String(format: String(localized: "conversation.audio.expiresIn", defaultValue: "Expires in %dm", bundle: .module), minutes)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension ConversationMessage {
    /// The bubble text: an audio message shows its transcript.
    var macBodyText: String {
        if let audio = audioAttachment?.audio { return audio.transcript ?? "" }
        return text
    }

    var macImageAttachments: [ConversationAttachment] {
        attachments.filter { $0.kind == .image }
    }
}

/// Audio bubble metrics for macOS (the iOS layout scaled to Messages' 13 pt
/// text and 32 pt single-line bubble).
enum MacAudioBubbleLayout {
    static let rowHeight: CGFloat = 32
    static let leadingInset: CGFloat = 8
    static let playSize: CGFloat = 18
    static let playGap: CGFloat = 5
    static let durationGap: CGFloat = 6
    static let durationWidth: CGFloat = 28
    static let trailingInset: CGFloat = 10
    static let barWidth: CGFloat = 2
    static let barPitch: CGFloat = 3.5
    static let maxBarHeight: CGFloat = 16
    static let minBarHeight: CGFloat = 2
    nonisolated(unsafe) static let durationFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    static func waveformWidth(duration: TimeInterval, limit: CGFloat) -> CGFloat {
        let natural = 56 + CGFloat(duration) * 6
        let bars = floor(min(natural, limit) / barPitch)
        return max(barPitch * 10, bars * barPitch - (barPitch - barWidth))
    }

    struct Result {
        var bodyWidth: CGFloat
        var height: CGFloat
        var transcript: CGRect?
    }

    static func compute(audio: ConversationAudioInfo, text: NSAttributedString, maxBubble: CGFloat) -> Result {
        let t = MacConversationTheme.self
        let chrome = leadingInset + playSize + playGap + durationGap + durationWidth + trailingInset
        var bodyWidth = chrome + waveformWidth(duration: audio.duration, limit: maxBubble - chrome)
        var height = rowHeight
        var transcript: CGRect?
        if text.length > 0 {
            let size = MacMessageLayout.measure(text, maxWidth: maxBubble - 2 * t.bubbleHorizontalPadding)
            bodyWidth = max(bodyWidth, min(maxBubble, size.width + 2 * t.bubbleHorizontalPadding))
            let textHeight = max(size.height, t.lineHeight)
            transcript = CGRect(x: t.bubbleHorizontalPadding, y: rowHeight - 4 - t.bubbleTextLift, width: size.width + 1, height: textHeight)
            height = rowHeight - 4 + textHeight + t.bubbleVerticalPadding
        }
        return Result(bodyWidth: ceil(bodyWidth), height: height, transcript: transcript)
    }
}

@MainActor
protocol MacAudioMessageDelegate: AnyObject {
    var audioPlayer: ConversationAudioPlayer { get }
    func keepAudio(messageID: String)
}

/// Peak-level bars; bars left of `progress` draw in `playedColor`. Click or
/// drag across it to scrub.
final class MacAudioWaveformView: MacFlippedView {
    var levels: [Float] = [] { didSet { needsDisplay = true } }
    var progress: CGFloat = 0 { didSet { if oldValue != progress { needsDisplay = true } } }
    var playedColor: NSColor = .white { didSet { needsDisplay = true } }
    var unplayedColor: NSColor = .white.withAlphaComponent(0.45) { didSet { needsDisplay = true } }
    var alignsTrailing = false
    var onScrub: ((CGFloat, Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let t = MacAudioBubbleLayout.self
        let count = Int((bounds.width + t.barPitch - t.barWidth) / t.barPitch)
        guard count > 0 else { return }
        let shown = alignsTrailing ? Array(levels.suffix(count)) : ConversationAudioInfo.resample(levels, count: count)
        let start = alignsTrailing ? bounds.width - CGFloat(shown.count) * t.barPitch + (t.barPitch - t.barWidth) : 0
        let edge = progress * bounds.width
        for (index, level) in shown.enumerated() {
            let height = max(t.minBarHeight, round(CGFloat(level) * min(t.maxBarHeight, bounds.height)))
            let x = start + CGFloat(index) * t.barPitch
            let bar = CGRect(x: x, y: (bounds.height - height) / 2, width: t.barWidth, height: height)
            (alignsTrailing || x + t.barWidth / 2 <= edge ? playedColor : unplayedColor).setFill()
            NSBezierPath(roundedRect: bar, xRadius: t.barWidth / 2, yRadius: t.barWidth / 2).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        onScrub == nil ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        scrub(event, finished: false)
    }

    override func mouseDragged(with event: NSEvent) {
        scrub(event, finished: false)
    }

    override func mouseUp(with event: NSEvent) {
        scrub(event, finished: true)
    }

    private func scrub(_ event: NSEvent, finished: Bool) {
        let x = convert(event.locationInWindow, from: nil).x
        onScrub?(min(1, max(0, x / max(1, bounds.width))), finished)
    }
}

/// Play/pause, waveform and duration of one audio message.
final class MacAudioMessageView: MacFlippedView {
    let playButton = NSButton()
    let waveform = MacAudioWaveformView()
    let durationLabel = makeMacLabel()
    private let spinner = NSProgressIndicator()
    private var displayLink: CADisplayLink?
    private var observer: UUID?
    private weak var player: ConversationAudioPlayer?
    private(set) var message: ConversationMessage?
    private var wasPlayingBeforeScrub: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        playButton.isBordered = false
        playButton.imagePosition = .imageOnly
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        playButton.setAccessibilityIdentifier("conversation.audio.play")
        addSubview(playButton)
        addSubview(waveform)
        durationLabel.font = MacAudioBubbleLayout.durationFont
        durationLabel.maximumNumberOfLines = 1
        addSubview(durationLabel)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        waveform.onScrub = { [weak self] fraction, finished in self?.scrub(to: fraction, finished: finished) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        MainActor.assumeIsolated {
            displayLink?.invalidate()
            if let observer { player?.removeObserver(observer) }
        }
    }

    func configure(message: ConversationMessage, isOutgoing: Bool, player: ConversationAudioPlayer?) {
        let audio = message.audioAttachment?.audio
        if self.message?.id != message.id || waveform.levels != audio?.waveform ?? [] {
            waveform.levels = audio?.waveform ?? []
        }
        self.message = message
        if self.player !== player || observer == nil {
            if let observer { self.player?.removeObserver(observer) }
            self.player = player
            observer = player?.addObserver { [weak self] in self?.refresh() }
        }
        let primary = isOutgoing ? NSColor.white : NSColor.labelColor
        playButton.contentTintColor = primary
        waveform.playedColor = primary
        waveform.unplayedColor = isOutgoing ? NSColor.white.withAlphaComponent(0.45) : NSColor.labelColor.withAlphaComponent(0.28)
        durationLabel.textColor = isOutgoing ? NSColor.white.withAlphaComponent(0.9) : MacConversationTheme.secondaryText
        refresh()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let t = MacAudioBubbleLayout.self
        let h = bounds.height
        playButton.frame = CGRect(x: t.leadingInset, y: (h - t.playSize) / 2, width: t.playSize, height: t.playSize)
        spinner.frame = playButton.frame.insetBy(dx: 1, dy: 1)
        let waveX = playButton.frame.maxX + t.playGap
        let durationX = bounds.width - t.trailingInset - t.durationWidth
        waveform.frame = CGRect(x: waveX, y: (h - t.maxBarHeight - 4) / 2, width: max(0, durationX - t.durationGap - waveX), height: t.maxBarHeight + 4)
        let lineHeight = ceil(t.durationFont.boundingRectForFont.height)
        durationLabel.frame = CGRect(x: durationX, y: (h - lineHeight) / 2, width: t.durationWidth + 4, height: lineHeight)
    }

    private func refresh() {
        guard let message else { return }
        let playing = player?.isPlaying(message.id) == true
        let loading = player?.loadingID == message.id
        let position = player?.position(for: message.id) ?? 0
        let duration = message.audioAttachment?.audio?.duration ?? 0
        waveform.progress = playing || position > 0 ? CGFloat(player?.progress(for: message) ?? 0) : 0
        let label = playing ? MacAudioStrings.pause : MacAudioStrings.play
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        playButton.setAccessibilityLabel(label)
        playButton.isHidden = loading
        loading ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        durationLabel.stringValue = MacAudioStrings.clock(playing || position > 0 ? position : duration)
        playing ? startDisplayLink() : stopDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(frameTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopDisplayLink() } else { refresh() }
    }

    @objc private func frameTick() {
        refresh()
    }

    @objc private func togglePlayback() {
        guard let message, let player else { return }
        player.toggle(message)
    }

    private func scrub(to fraction: CGFloat, finished: Bool) {
        guard let message, let player else { return }
        if wasPlayingBeforeScrub == nil {
            wasPlayingBeforeScrub = player.isPlaying(message.id)
            if wasPlayingBeforeScrub == true { player.pause() }
        }
        player.seek(message, to: Double(fraction))
        if finished {
            if wasPlayingBeforeScrub == true { player.play(message) }
            wasPlayingBeforeScrub = nil
        }
        refresh()
    }
}

/// "Expires in 2m  Keep" under an audio message, or "Kept".
final class MacAudioExpiryLabel: NSTextField {
    var onKeep: (() -> Void)?
    private var canKeep = false

    func configure(audio: ConversationAudioInfo, isOutgoing: Bool, now: Date = Date()) {
        alignment = isOutgoing ? .right : .left
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let gray: [NSAttributedString.Key: Any] = [.font: MacConversationTheme.footerFont, .foregroundColor: MacConversationTheme.secondaryText, .paragraphStyle: paragraph]
        if audio.isKept || audio.expiresAt == nil {
            canKeep = false
            attributedStringValue = NSAttributedString(string: MacAudioStrings.kept, attributes: gray)
            return
        }
        canKeep = true
        let minutes = max(1, Int(ceil((audio.expiresAt ?? now).timeIntervalSince(now) / 60)))
        let text = NSMutableAttributedString(string: MacAudioStrings.expiresIn(minutes: minutes) + "  ", attributes: gray)
        text.append(NSAttributedString(string: MacAudioStrings.keep, attributes: [.font: MacConversationTheme.footerFont, .foregroundColor: NSColor.systemBlue, .paragraphStyle: paragraph]))
        attributedStringValue = text
    }

    override func mouseDown(with event: NSEvent) {
        if canKeep { onKeep?() } else { super.mouseDown(with: event) }
    }
}

@MainActor
final class MacAudioRowViews {
    let message = MacAudioMessageView()
    let expiry: MacAudioExpiryLabel = {
        let label = MacAudioExpiryLabel(labelWithString: "")
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        return label
    }()
}

extension MacMessageRowView {
    func configureAudio(_ model: MacMessageRowModel, layout: MacMessageLayout) {
        guard let frame = layout.audioFrame, let audio = model.message.audioAttachment?.audio else {
            audioViews?.message.isHidden = true
            audioViews?.expiry.isHidden = true
            return
        }
        let views: MacAudioRowViews
        if let existing = audioViews {
            views = existing
        } else {
            views = MacAudioRowViews()
            addSubview(views.message)
            addSubview(views.expiry)
            audioViews = views
        }
        views.message.isHidden = false
        views.message.frame = frame
        views.message.configure(message: model.message, isOutgoing: model.isOutgoing, player: audioDelegate?.audioPlayer)
        if let expiryFrame = layout.audioExpiryFrame {
            views.expiry.isHidden = false
            views.expiry.frame = expiryFrame
            views.expiry.configure(audio: audio, isOutgoing: model.isOutgoing)
            let messageID = model.message.id
            views.expiry.onKeep = { [weak self] in self?.audioDelegate?.keepAudio(messageID: messageID) }
        } else {
            views.expiry.isHidden = true
        }
    }

    var audioAccessibilityText: String? {
        guard let audio = model?.message.audioAttachment?.audio else { return nil }
        return [MacAudioStrings.audioMessage, MacAudioStrings.clock(audio.duration), audio.transcript].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Controller

extension MacConversationViewController: MacAudioMessageDelegate {
    func keepAudio(messageID: String) {
        store.keepAudio(messageID: messageID)
    }

    func installAudio() {
        audioPlayer.nextMessage = { [weak self] finishedID in self?.audioMessage(after: finishedID) }
        audioPlayer.onFinished = { [weak self] messageID in self?.store.audioPlayed(messageID: messageID) }
        audioComposer.install()
    }

    func audioMessage(after messageID: String) -> ConversationMessage? {
        guard let finished = store.message(id: messageID), finished.senderID != store.meID,
              let index = store.messages.firstIndex(where: { $0.id == messageID }),
              index + 1 < store.messages.count else { return nil }
        let next = store.messages[index + 1]
        guard next.senderID != store.meID, next.audioAttachment != nil else { return nil }
        return next
    }
}

/// macOS record button flow: the field's waveform button starts recording;
/// the field shows a cancel button, live meter, timer and stop; stopping
/// reviews (play, waveform, duration, send).
@MainActor
final class MacAudioComposer: NSObject {
    private weak var controller: MacConversationViewController?
    private var recorder: ConversationAudioRecorder?
    private let field = MacAudioRecordingFieldView()
    private var displayLink: CADisplayLink?
    private var reviewPlayer: AVAudioPlayer?
    private var startTask: Task<Void, Never>?
    private let noticeLabel = makeMacLabel()
    private var noticeTask: Task<Void, Never>?
    var clock: any Clock<Duration> = ContinuousClock()

    init(controller: MacConversationViewController) {
        self.controller = controller
        super.init()
        field.onStop = { [weak self] in self?.stopToReview() }
        field.onSend = { [weak self] in self?.send() }
        field.onPlay = { [weak self] in self?.toggleReviewPlayback() }
        field.onCancel = { [weak self] in self?.cancel() }
    }

    var isActive: Bool { recorder != nil || startTask != nil }

    func install() {
        guard let composer = controller?.composer else { return }
        let click = NSClickGestureRecognizer(target: self, action: #selector(recordClicked))
        composer.audioButton.addGestureRecognizer(click)
        composer.audioButton.setAccessibilityRole(.button)
        composer.audioButton.setAccessibilityIdentifier("conversation.composer.record")
    }

    @objc private func recordClicked() {
        start()
    }

    func start() {
        guard !isActive, let controller else { return }
        if ConversationAudioRecorder.Input.fromEnvironment == .microphone, AVCaptureDevice.default(for: .audio) == nil {
            showUnavailableNotice()
            return
        }
        let recorder = ConversationAudioRecorder()
        recorder.syntheticTranscript = Self.syntheticPhrases.randomElement()
        self.recorder = recorder
        show(in: controller.composer)
        field.mode = .recording
        field.update(levels: [], time: 0)
        startTask = Task { [weak self] in
            do {
                try await recorder.start()
                guard let self, self.recorder === recorder else { return }
                self.startTask = nil
                self.startDisplayLink()
            } catch {
                guard let self else { return }
                self.startTask = nil
                self.dismiss()
                self.showUnavailableNotice()
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

    func send() {
        guard let recorder, let controller else { return }
        reviewPlayer?.stop()
        reviewPlayer = nil
        if recorder.state == .recording { stopDisplayLink() }
        guard let recorded = recorder.finish() else {
            dismiss()
            return
        }
        dismiss()
        _ = controller.store.sendAudio(data: recorded.data, info: recorded.info, replyToID: controller.replyTarget?.id)
    }

    func cancel() {
        reviewPlayer?.stop()
        reviewPlayer = nil
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
        reviewPlayer?.play()
        startDisplayLink()
    }

    private func show(in composer: MacComposerView) {
        field.frame = composer.fieldContent.bounds
        field.autoresizingMask = [.width, .height]
        composer.fieldContent.addSubview(field)
        composer.scrollView.isHidden = true
        composer.placeholder.isHidden = true
        composer.audioButton.isHidden = true
    }

    private func dismiss() {
        stopDisplayLink()
        startTask?.cancel()
        startTask = nil
        recorder = nil
        field.removeFromSuperview()
        guard let composer = controller?.composer else { return }
        composer.scrollView.isHidden = false
        composer.text = composer.text
        composer.needsLayout = true
    }

    /// The iOS 26 notice, by analogy (macOS was not measured): centered
    /// secondary text in the field for about 3 s.
    func showUnavailableNotice() {
        guard let composer = controller?.composer else { return }
        noticeTask?.cancel()
        noticeLabel.stringValue = String(localized: "conversation.audio.unavailable", defaultValue: "Audio recording not available", bundle: .module)
        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.alignment = .center
        noticeLabel.maximumNumberOfLines = 1
        let content = composer.fieldContent.bounds
        noticeLabel.frame = CGRect(x: 0, y: content.height - 32 + (32 - 14) / 2, width: content.width, height: 14)
        noticeLabel.autoresizingMask = [.width]
        composer.fieldContent.addSubview(noticeLabel)
        composer.placeholder.isHidden = true
        let clock = clock
        noticeTask = Task { [weak self] in
            try? await clock.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.noticeLabel.removeFromSuperview()
            composer.text = composer.text
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil, let view = controller?.view else { return }
        let link = view.displayLink(target: self, selector: #selector(frameTick))
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
            field.setReview(playing: playing, progress: playing ? CGFloat(reviewPlayer.currentTime / max(0.01, reviewPlayer.duration)) : 0, time: playing ? reviewPlayer.currentTime : recorder.duration)
            if !playing {
                self.reviewPlayer = nil
                stopDisplayLink()
            }
        case .idle:
            stopDisplayLink()
        }
    }

    static let syntheticPhrases = [
        "Hey, just checking in, call me when you're free.",
        "On my way, see you in ten.",
        "I pushed the fix, can you try the new build?",
        "Sounds good to me.",
    ]
}

/// The composer field while recording or reviewing an audio message.
final class MacAudioRecordingFieldView: MacFlippedView {
    enum Mode { case recording, review }
    var mode: Mode = .recording { didSet { applyMode() } }
    var onStop: (() -> Void)?
    var onSend: (() -> Void)?
    var onPlay: (() -> Void)?
    var onCancel: (() -> Void)?

    private let cancelButton = NSButton()
    private let timeLabel = makeMacLabel()
    private let waveform = MacAudioWaveformView()
    private let stopButton = NSButton()
    private let playButton = NSButton()
    private let sendButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("conversation.composer.recording")
        func symbolButton(_ button: NSButton, _ symbol: String, _ size: CGFloat, _ tint: NSColor, _ label: String, _ id: String, _ action: Selector) {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
            button.contentTintColor = tint
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(id)
            addSubview(button)
        }
        symbolButton(cancelButton, "xmark.circle.fill", 14, .tertiaryLabelColor, String(localized: "conversation.audio.cancel", defaultValue: "Cancel Recording", bundle: .module), "conversation.recording.cancel", #selector(cancelTapped))
        symbolButton(stopButton, "stop.circle.fill", 18, .systemRed, String(localized: "conversation.audio.stop", defaultValue: "Stop Recording", bundle: .module), "conversation.recording.stop", #selector(stopTapped))
        symbolButton(playButton, "play.fill", 12, .systemBlue, MacAudioStrings.play, "conversation.recording.play", #selector(playTapped))
        symbolButton(sendButton, "arrow.up.circle.fill", 20, .systemBlue, String(localized: "conversation.composer.send", defaultValue: "Send", bundle: .module), "conversation.recording.send", #selector(sendTapped))
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timeLabel.maximumNumberOfLines = 1
        addSubview(timeLabel)
        addSubview(waveform)
        applyMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let rowY = bounds.height - 32
        let midY = rowY + 16
        cancelButton.frame = CGRect(x: 6, y: midY - 10, width: 20, height: 20)
        stopButton.frame = CGRect(x: bounds.width - 30, y: midY - 12, width: 24, height: 24)
        sendButton.frame = stopButton.frame
        let barsHeight = MacAudioBubbleLayout.maxBarHeight + 4
        switch mode {
        case .recording:
            timeLabel.frame = CGRect(x: cancelButton.frame.maxX + 6, y: midY - 8, width: 40, height: 17)
            let waveX = timeLabel.frame.maxX + 6
            waveform.frame = CGRect(x: waveX, y: midY - barsHeight / 2, width: max(0, stopButton.frame.minX - 8 - waveX), height: barsHeight)
        case .review:
            playButton.frame = CGRect(x: cancelButton.frame.maxX + 4, y: midY - 10, width: 20, height: 20)
            timeLabel.frame = CGRect(x: sendButton.frame.minX - 44, y: midY - 8, width: 40, height: 17)
            let waveX = playButton.frame.maxX + 6
            waveform.frame = CGRect(x: waveX, y: midY - barsHeight / 2, width: max(0, timeLabel.frame.minX - 6 - waveX), height: barsHeight)
        }
    }

    private func applyMode() {
        let recording = mode == .recording
        stopButton.isHidden = !recording
        playButton.isHidden = recording
        sendButton.isHidden = recording
        waveform.alignsTrailing = recording
        waveform.playedColor = recording ? .systemRed : .systemBlue
        waveform.unplayedColor = NSColor.secondaryLabelColor.withAlphaComponent(0.6)
        timeLabel.alignment = recording ? .left : .right
        timeLabel.textColor = recording ? .labelColor : .secondaryLabelColor
        needsLayout = true
    }

    func update(levels: [Float], time: TimeInterval) {
        waveform.levels = levels
        timeLabel.stringValue = MacAudioStrings.clock(time)
    }

    func setReview(playing: Bool, progress: CGFloat, time: TimeInterval) {
        waveform.progress = progress
        timeLabel.stringValue = MacAudioStrings.clock(time)
        let label = playing ? MacAudioStrings.pause : MacAudioStrings.play
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
    }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func stopTapped() { onStop?() }
    @objc private func playTapped() { onPlay?() }
    @objc private func sendTapped() { onSend?() }
}
#endif
