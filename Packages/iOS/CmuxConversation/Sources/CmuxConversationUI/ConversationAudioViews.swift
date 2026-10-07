#if canImport(UIKit)
import CmuxConversationCore
import UIKit

enum AudioMessageStrings {
    static var audioMessage: String { String(localized: "conversation.audio.message", defaultValue: "Audio Message", bundle: .module) }
    static var play: String { String(localized: "conversation.audio.play", defaultValue: "Play", bundle: .module) }
    static var pause: String { String(localized: "conversation.audio.pause", defaultValue: "Pause", bundle: .module) }
    static var keep: String { String(localized: "conversation.audio.keep", defaultValue: "Keep", bundle: .module) }
    static var kept: String { String(localized: "conversation.audio.kept", defaultValue: "Kept", bundle: .module) }

    static func expiresIn(minutes: Int) -> String {
        String(format: String(localized: "conversation.audio.expiresIn", defaultValue: "Expires in %dm", bundle: .module), minutes)
    }

    /// "0:07", the duration format of the bubble and the recorder.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension ConversationMessage {
    /// What the bubble's text label shows: the transcript of an audio message.
    var bodyText: String {
        if let audio = audioAttachment?.audio { return audio.transcript ?? "" }
        return text
    }

    var imageAttachments: [ConversationAttachment] {
        attachments.filter { $0.kind == .image }
    }
}

/// Audio bubble metrics (iOS 26 Messages). The row holds the play glyph, the
/// waveform and the duration; a transcript wraps below it in the same bubble.
enum AudioBubbleLayout {
    static let rowHeight: CGFloat = 44
    static let leadingInset: CGFloat = 10
    static let playSize: CGFloat = 26
    static let playGap: CGFloat = 6
    static let durationGap: CGFloat = 8
    static let durationWidth: CGFloat = 36
    static let trailingInset: CGFloat = 13
    static let barWidth: CGFloat = 2
    static let barPitch: CGFloat = 4
    static let maxBarHeight: CGFloat = 22
    static let minBarHeight: CGFloat = 2
    static let durationFont = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular)

    /// Waveform width for a recording: longer recordings draw wider, up to the bubble limit.
    static func waveformWidth(duration: TimeInterval, limit: CGFloat) -> CGFloat {
        let natural = 64 + CGFloat(duration) * 7
        let bars = floor(min(natural, limit) / barPitch)
        return max(barPitch * 10, bars * barPitch - (barPitch - barWidth))
    }

    struct Result {
        var bodyWidth: CGFloat
        var height: CGFloat
        /// In body coordinates (origin at the body's top-left).
        var row: CGRect
        var transcript: CGRect?
    }

    static func compute(audio: ConversationAudioInfo, text: NSAttributedString, maxBubbleWidth: CGFloat) -> Result {
        let chrome = leadingInset + playSize + playGap + durationGap + durationWidth + trailingInset
        let waveform = waveformWidth(duration: audio.duration, limit: maxBubbleWidth - chrome)
        var bodyWidth = chrome + waveform
        var height = rowHeight
        var transcript: CGRect?
        if text.length > 0 {
            let t = ConversationTheme.self
            let size = MessageCellLayout.measure(text, maxWidth: maxBubbleWidth - 2 * t.bubbleHorizontalPadding)
            bodyWidth = max(bodyWidth, min(maxBubbleWidth, size.width + 2 * t.bubbleHorizontalPadding))
            let textHeight = max(size.height, t.lineHeight)
            transcript = CGRect(x: t.bubbleHorizontalPadding, y: rowHeight - 6 - t.bodyGlyphLift, width: size.width, height: textHeight)
            height = rowHeight - 6 + textHeight + t.bubbleVerticalPadding
        }
        return Result(bodyWidth: ceil(bodyWidth), height: height, row: CGRect(x: 0, y: 0, width: ceil(bodyWidth), height: rowHeight), transcript: transcript)
    }
}

@MainActor
protocol AudioMessageCellDelegate: AnyObject {
    var audioPlayer: ConversationAudioPlayer { get }
    func keepAudio(messageID: String)
}

/// Peak-level bars. Bars left of `progress` draw in `playedColor`.
final class AudioWaveformView: UIView {
    var levels: [Float] = [] { didSet { setNeedsDisplay() } }
    var progress: CGFloat = 0 { didSet { if oldValue != progress { setNeedsDisplay() } } }
    var playedColor: UIColor = .white { didSet { setNeedsDisplay() } }
    var unplayedColor: UIColor = .white.withAlphaComponent(0.45) { didSet { setNeedsDisplay() } }
    /// Draw the newest levels right-aligned (live recording meter).
    var alignsTrailing = false
    var onScrub: ((CGFloat, UIGestureRecognizer.State) -> Void)? {
        didSet { scrubPan.isEnabled = onScrub != nil }
    }
    private lazy var scrubPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(scrubbed(_:)))
        pan.isEnabled = false
        addGestureRecognizer(pan)
        return pan
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        _ = scrubPan
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var barCount: Int {
        Int((bounds.width + AudioBubbleLayout.barPitch - AudioBubbleLayout.barWidth) / AudioBubbleLayout.barPitch)
    }

    override func draw(_ rect: CGRect) {
        let count = barCount
        guard count > 0 else { return }
        let shown: [Float]
        if alignsTrailing {
            shown = Array(levels.suffix(count))
        } else {
            shown = ConversationAudioInfo.resample(levels, count: count)
        }
        let t = AudioBubbleLayout.self
        let start = alignsTrailing ? bounds.width - CGFloat(shown.count) * t.barPitch + (t.barPitch - t.barWidth) : 0
        let playedEdge = progress * bounds.width
        for (index, level) in shown.enumerated() {
            let height = max(t.minBarHeight, round(CGFloat(level) * min(t.maxBarHeight, bounds.height)))
            let x = start + CGFloat(index) * t.barPitch
            let bar = CGRect(x: x, y: (bounds.height - height) / 2, width: t.barWidth, height: height)
            let color = alignsTrailing || x + t.barWidth / 2 <= playedEdge ? playedColor : unplayedColor
            color.setFill()
            UIBezierPath(roundedRect: bar, cornerRadius: t.barWidth / 2).fill()
        }
    }

    @objc private func scrubbed(_ pan: UIPanGestureRecognizer) {
        let x = pan.location(in: self).x
        onScrub?(min(1, max(0, x / max(1, bounds.width))), pan.state)
    }

    /// A horizontal drag that starts on the waveform scrubs; the transcript's
    /// own horizontal pans (reply, timestamps) and scrolling yield to it.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard onScrub != nil, let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let velocity = pan.velocity(in: self)
        let horizontal = abs(velocity.x) > abs(velocity.y)
        // The scrub takes horizontal drags only; everything else yields to it.
        return pan === scrubPan ? horizontal : !horizontal
    }
}

/// Play/pause, waveform and duration of one audio message.
final class AudioMessageView: UIView {
    let playButton = UIButton(type: .custom)
    let waveform = AudioWaveformView()
    let durationLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var displayLink: CADisplayLink?
    private var observer: UUID?
    private weak var player: ConversationAudioPlayer?
    private(set) var message: ConversationMessage?
    private var isOutgoing = false
    private var wasPlayingBeforeScrub = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(playButton)
        addSubview(waveform)
        addSubview(durationLabel)
        addSubview(spinner)
        spinner.hidesWhenStopped = true
        durationLabel.font = AudioBubbleLayout.durationFont
        durationLabel.textAlignment = .left
        playButton.accessibilityIdentifier = "conversation.audio.play"
        playButton.addAction(UIAction { [weak self] _ in self?.togglePlayback() }, for: .touchUpInside)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
        waveform.onScrub = { [weak self] fraction, state in self?.scrub(to: fraction, state: state) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(message: ConversationMessage, isOutgoing: Bool, player: ConversationAudioPlayer?) {
        let sameMessage = self.message?.id == message.id
        self.message = message
        self.isOutgoing = isOutgoing
        if self.player !== player || observer == nil {
            if let observer { self.player?.removeObserver(observer) }
            self.player = player
            observer = player?.addObserver { [weak self] in self?.refresh() }
        }
        let audio = message.audioAttachment?.audio
        if !sameMessage || waveform.levels != audio?.waveform ?? [] {
            waveform.levels = audio?.waveform ?? []
        }
        let primary: UIColor = isOutgoing ? ConversationTheme.outgoingText : ConversationTheme.incomingText
        waveform.playedColor = primary
        waveform.unplayedColor = isOutgoing
            ? UIColor.white.withAlphaComponent(0.45)
            : UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.32) : UIColor(white: 0, alpha: 0.28) }
        playButton.tintColor = primary
        spinner.color = primary
        durationLabel.textColor = isOutgoing ? UIColor.white.withAlphaComponent(0.9) : ConversationTheme.secondaryText
        refresh()
        setNeedsLayout()
    }

    deinit {
        MainActor.assumeIsolated {
            displayLink?.invalidate()
            if let observer { player?.removeObserver(observer) }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let t = AudioBubbleLayout.self
        let h = bounds.height
        playButton.frame = CGRect(x: t.leadingInset, y: (h - t.playSize) / 2, width: t.playSize, height: t.playSize)
        spinner.center = playButton.center
        let waveX = playButton.frame.maxX + t.playGap
        let durationX = bounds.width - t.trailingInset - t.durationWidth
        waveform.frame = CGRect(x: waveX, y: (h - t.maxBarHeight - 4) / 2, width: max(0, durationX - t.durationGap - waveX), height: t.maxBarHeight + 4)
        durationLabel.frame = CGRect(x: durationX, y: 0, width: t.durationWidth, height: h)
    }

    private func refresh() {
        guard let message else { return }
        let audio = message.audioAttachment?.audio
        let playing = player?.isPlaying(message.id) == true
        let loading = player?.loadingID == message.id
        let position = player?.position(for: message.id) ?? 0
        let duration = audio?.duration ?? 0
        let progress = player.map { CGFloat($0.progress(for: message)) } ?? 0
        waveform.progress = playing || position > 0 ? progress : 0
        let symbol = playing ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)), for: .normal)
        playButton.accessibilityLabel = playing ? AudioMessageStrings.pause : AudioMessageStrings.play
        playButton.alpha = loading ? 0 : 1
        loading ? spinner.startAnimating() : spinner.stopAnimating()
        durationLabel.text = AudioMessageStrings.clock(playing || position > 0 ? position : duration)
        accessibilityValue = durationLabel.text
        playing ? startDisplayLink() : stopDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil, window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frameTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopDisplayLink() } else { refresh() }
    }

    @objc private func frameTick() {
        refresh()
    }

    @objc private func tapped() {
        togglePlayback()
    }

    private func togglePlayback() {
        guard let message, let player else { return }
        player.toggle(message)
    }

    private func scrub(to fraction: CGFloat, state: UIGestureRecognizer.State) {
        guard let message, let player else { return }
        switch state {
        case .began:
            wasPlayingBeforeScrub = player.isPlaying(message.id)
            if wasPlayingBeforeScrub { player.pause() }
            player.seek(message, to: Double(fraction))
        case .changed:
            player.seek(message, to: Double(fraction))
        case .ended, .cancelled, .failed:
            player.seek(message, to: Double(fraction))
            if wasPlayingBeforeScrub { player.play(message) }
        default:
            break
        }
        refresh()
    }
}

/// "Expires in 2m  Keep" under an audio message, or "Kept" once kept.
final class AudioExpiryView: UILabel {
    var onKeep: (() -> Void)?
    private var canKeep = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(audio: ConversationAudioInfo, isOutgoing: Bool, now: Date = Date()) {
        textAlignment = isOutgoing ? .right : .left
        let gray: [NSAttributedString.Key: Any] = [.font: ConversationTheme.footerFont, .foregroundColor: ConversationTheme.secondaryText]
        if audio.isKept || audio.expiresAt == nil {
            canKeep = false
            attributedText = NSAttributedString(string: AudioMessageStrings.kept, attributes: gray)
            return
        }
        canKeep = true
        let minutes = max(1, Int(ceil((audio.expiresAt ?? now).timeIntervalSince(now) / 60)))
        let text = NSMutableAttributedString(string: AudioMessageStrings.expiresIn(minutes: minutes) + "  ", attributes: gray)
        text.append(NSAttributedString(string: AudioMessageStrings.keep, attributes: [.font: ConversationTheme.footerFont, .foregroundColor: UIColor.systemBlue]))
        attributedText = text
    }

    @objc private func tapped() {
        if canKeep { onKeep?() }
    }
}

/// The audio subviews a message cell adds on first use.
@MainActor
final class AudioMessageCellViews {
    let message = AudioMessageView()
    let expiry = AudioExpiryView()
}

extension MessageCell {
    func configureAudio(model: MessageRowModel, layout: MessageCellLayout) {
        guard let audioFrame = layout.audioFrame, let audio = model.message.audioAttachment?.audio else {
            audioViews?.message.isHidden = true
            audioViews?.expiry.isHidden = true
            return
        }
        let views: AudioMessageCellViews
        if let existing = audioViews {
            views = existing
        } else {
            views = AudioMessageCellViews()
            shiftable.insertSubview(views.message, aboveSubview: bubble)
            contentView.addSubview(views.expiry)
            audioViews = views
        }
        views.message.isHidden = false
        views.message.frame = audioFrame
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
        guard let model, let audio = model.message.audioAttachment?.audio else { return nil }
        return [AudioMessageStrings.audioMessage, AudioMessageStrings.clock(audio.duration), audio.transcript].compactMap { $0 }.joined(separator: ", ")
    }
}
#endif
