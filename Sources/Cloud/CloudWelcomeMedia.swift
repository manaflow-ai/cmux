import AppKit
import AVFoundation
import CmuxFoundation
import ImageIO
import Observation
import SwiftUI

/// One feature in the welcome's media slider: a short looping clip, a title
/// and one line. The clip is `<id>.mp4` (or `.mov`, `.gif`) in the app's
/// `CloudWelcome` resources; until it exists the slide shows a placeholder.
struct CloudWelcomeSlide: Identifiable, Equatable {
    let id: String
    let symbol: String
    let title: String
    let caption: String

    static let all: [CloudWelcomeSlide] = [
        CloudWelcomeSlide(
            id: "spin-up",
            symbol: "bolt",
            title: String(localized: "cloud.welcome.slide.spinUp.title", defaultValue: "Create machines in seconds"),
            caption: String(
                localized: "cloud.welcome.slide.spinUp.caption",
                defaultValue: "Each one opens as a regular cmux workspace with a terminal ready."
            )
        ),
        CloudWelcomeSlide(
            id: "keeps-running",
            symbol: "terminal",
            title: String(localized: "cloud.welcome.slide.keepsRunning.title", defaultValue: "Runs while you’re away"),
            caption: String(
                localized: "cloud.welcome.slide.keepsRunning.caption",
                defaultValue: "Agents and terminals keep running after you close your laptop."
            )
        ),
        CloudWelcomeSlide(
            id: "displays",
            symbol: "display",
            title: String(localized: "cloud.welcome.slide.displays.title", defaultValue: "See the machine’s desktop"),
            caption: String(
                localized: "cloud.welcome.slide.displays.caption",
                defaultValue: "Open a display next to your terminal and watch apps and browsers run."
            )
        ),
        CloudWelcomeSlide(
            id: "invite",
            symbol: "person.badge.plus",
            title: String(localized: "cloud.welcome.slide.invite.title", defaultValue: "Invite your team"),
            caption: String(
                localized: "cloud.welcome.slide.invite.caption",
                defaultValue: "Add teammates by email so they can use your team’s Cloud machines."
            )
        ),
        CloudWelcomeSlide(
            id: "team",
            symbol: "person.2",
            title: String(localized: "cloud.welcome.slide.team.title", defaultValue: "Work together on one machine"),
            caption: String(
                localized: "cloud.welcome.slide.team.caption",
                defaultValue: "Invite teammates to the same machine and collaborate in a shared workspace."
            )
        ),
    ]
}

/// The welcome's media slider: one clip at a time in a rounded frame, a pager
/// whose active pill fills with the clip's own playhead, and the slide's title
/// and line. Autoplay moves on when the clip ends and a click on the clip
/// pauses; manual loops each clip until an arrow or dot moves on. With Reduce
/// Motion it never moves on by itself.
struct CloudWelcomeMediaCarousel: View {
    let slides: [CloudWelcomeSlide]
    /// Where a slide's clip lives. The app reads its bundle; the lab a folder.
    let mediaURL: (CloudWelcomeSlide) -> URL?
    var mediaSize = CGSize(width: 340, height: 212)
    /// True: plays through on its own, a click on the clip pauses. False: each
    /// clip loops until the viewer moves on with the arrows or dots.
    var autoplays = true
    /// Manual with the features as a list beside the clip (rows to click, every
    /// title readable at a glance) in place of the dots and caption below it.
    var showsFeatureList = false
    /// List variant: a bar for the current feature and a dot for each other one,
    /// each centered on its text, in place of a bar per feature.
    var listUsesDots = false

    /// How long a slide without a clip (or with an unreadable one) stays up.
    private static let fallbackDuration: Double = 4
    /// Short draft clips still need enough time for the title and caption to be
    /// read. They loop until this dwell has elapsed, then advance on a loop
    /// boundary so the transition never cuts through a frame.
    private nonisolated static let minimumReadableMovieDwell: Double = 4
    private static let pillWidth: CGFloat = 36
    private static let dotSize: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var duration: Double = fallbackDuration
    @State private var durationLoadFailed = false
    @State private var isHoveringMedia = false
    @State private var hoveredRow: String?
    @State private var playback = Playback()

    private var index: Int { playback.index }
    private var movieFailed: Bool { durationLoadFailed || playback.movieFailed }

    var body: some View {
        Group {
            if showsFeatureList {
                HStack(alignment: .center, spacing: 18) {
                    featureList
                        .frame(maxWidth: .infinity, alignment: .leading)
                    media
                }
                .padding(.leading, 28)
                .padding(.trailing, 28)
            } else {
                stacked
            }
        }
        .task { await observePlayback() }
        .task(id: currentSlide.id) { await loadDuration() }
        .task(id: AdvanceKey(slide: currentSlide.id, isPaused: playback.isPaused, duration: duration, movieFailed: movieFailed)) {
            await advanceWhenDone()
        }
    }

    /// The clip, the pager under it, and the slide's title and line.
    private var stacked: some View {
        VStack(spacing: 0) {
            media
            pager
                .padding(.top, 14)
            caption
                .padding(.top, 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(currentSlide.title)
        .accessibilityValue(currentSlide.caption)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: show((index + 1) % slides.count)
            case .decrement: show((index - 1 + slides.count) % slides.count)
            @unknown default: break
            }
        }
    }

    private var currentSlide: CloudWelcomeSlide { slides[index] }

    /// Beside the list the clip takes the room the titles don't need, so it
    /// reads larger (same 16:10, so recorded clips fit either layout).
    private var mediaFrame: CGSize {
        showsFeatureList ? CGSize(width: 390, height: 244) : mediaSize
    }

    // MARK: Feature list

    /// The row opens on a soft spring (``show(_:)``); the old line leaves fast,
    /// the new one fades in once there is room for it, settling down a touch.
    private static let captionTransition: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .offset(y: -3))
            .animation(.easeOut(duration: 0.3).delay(0.12)),
        removal: .opacity.animation(.easeOut(duration: 0.1))
    )

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(slides.enumerated()), id: \.element.id) { offset, slide in
                featureRow(slide, isCurrent: offset == index) {
                    show(offset)
                }
            }
        }
    }

    /// A feature: a segment of the rail and its title; the selected one lights
    /// its segment and opens to show its line, the rest stay quiet until hovered.
    private func featureRow(_ slide: CloudWelcomeSlide, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        let isHovered = hoveredRow == slide.id
        return Button(action: action) {
            HStack(alignment: listUsesDots ? .center : .top, spacing: 12) {
                if listUsesDots {
                    dotMarker(isCurrent: isCurrent, isHovered: isHovered)
                } else {
                    // Inset top and bottom so each feature has its own bar, with a
                    // clear gap to the next one.
                    railSegment(isCurrent: isCurrent)
                        .frame(width: 2.5)
                        .padding(.vertical, 4)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(slide.title)
                        .cmuxFont(size: 13, weight: .medium)
                        .foregroundStyle(isCurrent || isHovered ? Color.primary : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isCurrent {
                        Text(slide.caption)
                            .cmuxFont(size: 11.5)
                            .foregroundStyle(.secondary)
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(Self.captionTransition)
                    }
                }
                .padding(.vertical, 7)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredRow = slide.id
            } else if hoveredRow == slide.id {
                hoveredRow = nil
            }
        }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    // MARK: Media

    private var media: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            slideMedia(currentSlide)
                .id(currentSlide.id)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
        }
        .frame(width: mediaFrame.width, height: mediaFrame.height)
        .background(shape.fill(Color.black.opacity(0.35)))
        .overlay { mediaControls }
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture {
            if autoplays { setPaused(!playback.isPaused) }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHoveringMedia = hovering }
        }
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    /// Autoplay: a pause button while the pointer is over the clip (a play button
    /// stays while paused). Manual: previous and next arrows on hover.
    @ViewBuilder
    private var mediaControls: some View {
        if autoplays {
            if isHoveringMedia || playback.isPaused {
                controlButton(
                    symbol: playback.isPaused ? "play.fill" : "pause.fill",
                    label: playback.isPaused
                        ? String(localized: "cloud.welcome.slider.play", defaultValue: "Play")
                        : String(localized: "cloud.welcome.slider.pause", defaultValue: "Pause")
                ) {
                    setPaused(!playback.isPaused)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.opacity)
            }
        } else if isHoveringMedia, slides.count > 1, !showsFeatureList {
            HStack {
                controlButton(
                    symbol: "chevron.left",
                    label: String(localized: "cloud.welcome.slider.previous", defaultValue: "Previous")
                ) {
                    show((index - 1 + slides.count) % slides.count)
                }
                Spacer(minLength: 0)
                controlButton(
                    symbol: "chevron.right",
                    label: String(localized: "cloud.welcome.slider.next", defaultValue: "Next")
                ) {
                    show((index + 1) % slides.count)
                }
            }
            .padding(.horizontal, 10)
            .transition(.opacity)
        }
    }

    private func controlButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .cmuxFont(size: 11, weight: .bold)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func slideMedia(_ slide: CloudWelcomeSlide) -> some View {
        if let url = mediaURL(slide) {
            Player(url: url, playback: playback)
        } else {
            placeholder(slide)
        }
    }

    /// Until the clip is recorded: the slide's symbol and id, so a missing file
    /// is obvious in the lab and harmless if one ever ships without it.
    private func placeholder(_ slide: CloudWelcomeSlide) -> some View {
        VStack(spacing: 10) {
            Image(systemName: slide.symbol)
                .cmuxFont(size: 34, weight: .light)
                .foregroundStyle(Color.accentColor)
            Text(slide.title)
                .cmuxFont(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.14), Color.accentColor.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: Pager

    /// Dots for the other slides; the current one is a pill that fills with its
    /// clip's playhead. When a slide ends, its full pill springs down into a dot
    /// as the next dot springs open and starts filling.
    private var pager: some View {
        HStack(spacing: 6) {
            ForEach(Array(slides.enumerated()), id: \.element.id) { offset, slide in
                Button {
                    show(offset)
                } label: {
                    pagerMark(isCurrent: offset == index)
                        .contentShape(Rectangle().inset(by: -4))
                }
                .buttonStyle(.plain)
                .help(slide.title)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: index)
    }

    private func pagerMark(isCurrent: Bool) -> some View {
        Capsule(style: .continuous)
            .fill(Color.primary.opacity(isCurrent ? 0.16 : 0.25))
            .frame(width: isCurrent ? Self.pillWidth : Self.dotSize, height: Self.dotSize)
            .overlay(alignment: .leading) {
                if isCurrent {
                    TimelineView(.animation(paused: playback.isPaused || reduceMotion || !autoplays)) { context in
                        RailFill(fraction: progress(at: context.date), vertical: false, minimumLength: Self.dotSize)
                    }
                    .transition(.opacity)
                }
            }
            // The finished fill stays inside the pill as it springs closed.
            .clipShape(Capsule(style: .continuous))
    }

    /// Dots variant: the current feature's bar spans its title and line (and
    /// fills with the clip when autoplaying); the others are dots centered on
    /// their title. The dot stretches into the bar as a row becomes current.
    private func dotMarker(isCurrent: Bool, isHovered: Bool) -> some View {
        ZStack {
            if isCurrent {
                railSegment(isCurrent: true)
                    .frame(width: 2.5)
                    .padding(.vertical, 8)
                    .transition(.scale(scale: 0.1, anchor: .center).combined(with: .opacity))
            } else {
                Circle()
                    .fill(Color.primary.opacity(isHovered ? 0.5 : 0.25))
                    .frame(width: 5, height: 5)
                    .transition(.opacity)
            }
        }
        .frame(width: 5)
        .frame(maxHeight: .infinity)
    }

    /// A row's part of the rail. Manual: the selected one is lit. Autoplay: the
    /// selected one fills top to bottom with its clip, then the next row takes over.
    @ViewBuilder
    private func railSegment(isCurrent: Bool) -> some View {
        if isCurrent && autoplays && !reduceMotion {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.16))
                .overlay {
                    TimelineView(.animation(paused: playback.isPaused)) { context in
                        RailFill(fraction: progress(at: context.date), vertical: true)
                    }
                }
                .clipShape(Capsule(style: .continuous))
        } else {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(isCurrent ? 0.9 : 0.12))
        }
    }

    /// The clip's playhead when it is a movie, so the pill never drifts from
    /// what is on screen; the wall clock for a GIF or a placeholder.
    private func progress(at date: Date) -> Double {
        if reduceMotion || !autoplays { return 1 }
        if let fraction = playback.fraction { return fraction }
        return min(playback.elapsed(at: date) / max(duration, 0.1), 1)
    }

    // MARK: Caption

    private var caption: some View {
        VStack(spacing: 3) {
            Text(currentSlide.title)
                .cmuxFont(size: 15, weight: .semibold)
            Text(currentSlide.caption)
                .cmuxFont(size: 13)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 460)
        .id(currentSlide.id)
        .transition(.opacity)
    }

    // MARK: Clock

    private struct AdvanceKey: Equatable {
        let slide: String
        let isPaused: Bool
        let duration: Double
        let movieFailed: Bool
    }

    private func setPaused(_ paused: Bool) {
        playback.setPaused(paused)
    }

    private func show(_ newIndex: Int) {
        guard newIndex != index else { return }
        playback.detach()
        durationLoadFailed = false
        // Picking a slide plays it, even if the last one was paused.
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.88)) {
            playback.startNewSlide(at: newIndex)
        }
    }

    /// A movie's first play ended (the looper wrapped around): next slide.
    private func clipFinished() {
        guard autoplays, !reduceMotion, !playback.isPaused, slides.count > 1 else { return }
        guard Self.shouldAdvanceAfterMovie(elapsed: playback.elapsed(at: Date())) else { return }
        show((index + 1) % slides.count)
    }

    nonisolated static func shouldAdvanceAfterMovie(elapsed: Double) -> Bool {
        elapsed >= minimumReadableMovieDwell
    }

    /// A slide without a movie (GIF, placeholder) waits out its duration, then
    /// moves on. Pausing, a new slide or a newly loaded duration cancels this.
    private func advanceWhenDone() async {
        // The first slide's clock starts here for movies too, or a first clip
        // never reaches the minimum dwell and autoplay stays on slide 1.
        playback.startInitialSlideIfNeeded()
        let isMovie = Self.isMovie(mediaURL(currentSlide))
        guard autoplays, !reduceMotion, !playback.isPaused, slides.count > 1, (!isMovie || movieFailed) else { return }
        let remaining = duration - playback.elapsed(at: Date())
        if remaining > 0 {
            do { try await ContinuousClock().sleep(for: .seconds(remaining)) } catch { return }
        }
        // A pause or a new slide can land just as the wait ends.
        guard !Task.isCancelled, !playback.isPaused else { return }
        show((index + 1) % slides.count)
    }

    /// Consumes movie loop events for as long as this carousel is on screen.
    private func observePlayback() async {
        for await _ in playback.loopCompletions {
            guard !Task.isCancelled else { return }
            clipFinished()
        }
    }

    /// The slide stays up for one play of its clip.
    private func loadDuration() async {
        duration = Self.fallbackDuration
        durationLoadFailed = false
        guard let url = mediaURL(currentSlide) else { return }
        if url.pathExtension.lowercased() == "gif" {
            duration = await Self.gifDuration(url) ?? Self.fallbackDuration
        } else {
            do {
                let seconds = try await AVURLAsset(url: url).load(.duration).seconds
                if seconds.isFinite, seconds > 0.5 {
                    duration = seconds
                } else {
                    durationLoadFailed = true
                }
            } catch {
                durationLoadFailed = true
            }
        }
    }

    private static func isMovie(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.pathExtension.lowercased() != "gif"
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated private static func gifDuration(_ url: URL) async -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var total: Double = 0
        for frame in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0.1
            total += delay < 0.011 ? 0.1 : delay
        }
        return total > 0 ? total : nil
    }

    /// The pill's (or the list rail's) fill, drawn by Core Animation. The fill
    /// moves ~10 px a second; SwiftUI rounds sizes and offsets to whole pixels,
    /// so it stepped. A layer placed at fractional points is drawn antialiased
    /// between pixels, so it glides. Horizontal grows left to right, vertical
    /// top to bottom.
    private struct RailFill: NSViewRepresentable {
        let fraction: Double
        let vertical: Bool
        var minimumLength: CGFloat = 0

        func makeNSView(context: Context) -> FillView { FillView() }

        func updateNSView(_ view: FillView, context: Context) {
            view.configure(fraction: fraction, vertical: vertical, minimumLength: minimumLength)
        }

        final class FillView: NSView {
            private let fill = CALayer()
            private var fraction: Double = 0
            private var vertical = false
            private var minimumLength: CGFloat = 0

            override init(frame: NSRect) {
                super.init(frame: frame)
                wantsLayer = true
                layer?.masksToBounds = true
                fill.allowsEdgeAntialiasing = true
                layer?.addSublayer(fill)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

            func configure(fraction: Double, vertical: Bool, minimumLength: CGFloat) {
                self.fraction = fraction
                self.vertical = vertical
                self.minimumLength = minimumLength
                needsLayout = true
            }

            override func layout() {
                super.layout()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                let length = vertical ? bounds.height : bounds.width
                let visible = minimumLength + (length - minimumLength) * CGFloat(fraction)
                // Full length, slid in by a fractional amount (AppKit's y is up,
                // so a top-down fill slides down from above the top edge).
                fill.frame = vertical
                    ? CGRect(x: 0, y: bounds.height - visible, width: bounds.width, height: bounds.height)
                    : CGRect(x: visible - bounds.width, y: 0, width: bounds.width, height: bounds.height)
                let radius = min(bounds.width, bounds.height) / 2
                fill.cornerRadius = radius
                layer?.cornerRadius = radius
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    fill.backgroundColor = NSColor.labelColor.withAlphaComponent(0.85).cgColor
                }
                CATransaction.commit()
            }

            override func viewDidChangeEffectiveAppearance() {
                super.viewDidChangeEffectiveAppearance()
                needsLayout = true
            }
        }
    }

    /// Plays a clip muted and looping, filling the frame. Movies (the format to
    /// ship) decode in hardware and composite on the GPU through AVPlayerLayer;
    /// GIF is a fallback for quick drafts only (CPU decoded, 256 colors).
    private struct Player: NSViewRepresentable {
        let url: URL
        let playback: Playback

        func makeNSView(context: Context) -> NSView {
            if url.pathExtension.lowercased() == "gif" {
                let view = NSImageView()
                view.image = NSImage(contentsOf: url)
                view.animates = true
                view.imageScaling = .scaleProportionallyUpOrDown
                return view
            }
            return MovieView(url: url, playback: playback)
        }

        func updateNSView(_ nsView: NSView, context: Context) {}

        final class MovieView: NSView {
            private let player = AVQueuePlayer()
            private let playerLayer: AVPlayerLayer
            private var looper: AVPlayerLooper?
            private var readyObservation: NSKeyValueObservation?
            private var statusObservation: NSKeyValueObservation?
            private var loopObservation: NSKeyValueObservation?
            private weak var playback: Playback?

            init(url: URL, playback: Playback) {
                self.playback = playback
                playerLayer = AVPlayerLayer(player: player)
                super.init(frame: .zero)
                wantsLayer = true
                playerLayer.videoGravity = .resizeAspectFill
                // Hidden until the first frame is decoded, then faded in, so a
                // slide change never flashes an empty frame.
                playerLayer.opacity = 0
                layer = playerLayer
                statusObservation = player.observe(\.status, options: [.initial, .new]) { [weak playback, weak player] observedPlayer, _ in
                    guard observedPlayer.status == .failed else { return }
                    Task { @MainActor [weak playback, weak player] in
                        guard let playback, let player else { return }
                        playback.didFail(player)
                    }
                }
                readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { observedLayer, _ in
                    guard observedLayer.isReadyForDisplay else { return }
                    Task { @MainActor [weak observedLayer] in
                        guard let observedLayer else { return }
                        let fade = CABasicAnimation(keyPath: "opacity")
                        fade.fromValue = 0
                        fade.duration = 0.15
                        observedLayer.opacity = 1
                        observedLayer.add(fade, forKey: "fadeIn")
                    }
                }
                player.isMuted = true
                // A muted illustration must not keep the display awake or show up
                // in AirPlay / Now Playing.
                player.preventsDisplaySleepDuringVideoPlayback = false
                player.allowsExternalPlayback = false
                let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
                self.looper = looper
                loopObservation = looper.observe(\.loopCount, options: [.new]) { [weak playback, weak player] looper, _ in
                    guard looper.loopCount > 0 else { return }
                    Task { @MainActor [weak playback, weak player] in
                        // Only the current slide's movie moves the slider on.
                        guard let playback, let player else { return }
                        playback.didFinish(player)
                    }
                }
                playback.attach(player)
            }

            deinit {
                readyObservation?.invalidate()
                statusObservation?.invalidate()
                loopObservation?.invalidate()
                player.pause()
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        }
    }
}

extension CloudWelcomeMediaCarousel {
    /// The app's clips: `CloudWelcome/<id>.(mp4|mov|gif)` in the main bundle.
    /// Debug builds read the checkout's `Resources/CloudWelcome` first, at the
    /// moment the welcome opens: drop in a new clip and reopen it, no rebuild.
    static func bundledMediaURL(_ slide: CloudWelcomeSlide) -> URL? {
        #if DEBUG
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for ext in ["mp4", "mov", "gif"] {
            let url = checkout.appendingPathComponent("Resources/CloudWelcome/\(slide.id).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        #endif
        for ext in ["mp4", "mov", "gif"] {
            if let url = Bundle.main.url(forResource: slide.id, withExtension: ext, subdirectory: "CloudWelcome") {
                return url
            }
        }
        return nil
    }
}

extension CloudWelcomeMediaCarousel {
    /// The playing movie, shared between the player view (which owns it) and
    /// the pager (which reads its playhead and hears when it ends).
    @MainActor
    @Observable
    final class Playback {
        /// The event stream emitted by the current movie when it completes a loop.
        @ObservationIgnored private(set) var loopCompletions: AsyncStream<Void>
        @ObservationIgnored private let loopContinuation: AsyncStream<Void>.Continuation
        private weak var player: AVPlayer?
        private(set) var index = 0
        private(set) var isPaused = false
        private(set) var movieFailed = false
        private var pausedElapsed: Double?
        private var startedAt: Date?

        init() {
            (loopCompletions, loopContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        }

        deinit {
            loopContinuation.finish()
        }

        func attach(_ player: AVPlayer) {
            self.player = player
            if isPaused { player.pause() } else { player.play() }
        }

        /// A new slide is showing; the outgoing movie no longer drives the pager.
        func detach(_ candidate: AVPlayer? = nil) {
            guard candidate == nil || player === candidate else { return }
            player = nil
        }

        func didFinish(_ candidate: AVPlayer) {
            guard player === candidate else { return }
            loopContinuation.yield()
        }

        func didFail(_ candidate: AVPlayer) {
            guard player === candidate else { return }
            movieFailed = true
        }

        func setPaused(_ paused: Bool) {
            guard paused != isPaused else { return }
            let now = Date()
            if paused {
                pausedElapsed = elapsed(at: now)
                isPaused = true
                player?.pause()
            } else {
                if let held = pausedElapsed {
                    startedAt = now.addingTimeInterval(-held)
                }
                pausedElapsed = nil
                isPaused = false
                player?.play()
            }
        }

        /// Starts the new slide's playhead and clears any pause carried by the old slide.
        func startNewSlide(at newIndex: Int? = nil) {
            if let newIndex {
                index = newIndex
            }
            movieFailed = false
            startedAt = Date()
            pausedElapsed = nil
            isPaused = false
            player?.play()
        }

        /// Returns elapsed playhead time, including a held value while paused.
        func elapsed(at date: Date) -> Double {
            pausedElapsed ?? startedAt.map { date.timeIntervalSince($0) } ?? 0
        }

        func startInitialSlideIfNeeded() {
            guard startedAt == nil else { return }
            startedAt = Date()
        }

        /// How far through its current play the movie is, or nil without one.
        var fraction: Double? {
            guard let item = player?.currentItem else { return nil }
            let total = item.duration.seconds
            guard total.isFinite, total > 0 else { return nil }
            return min(max(item.currentTime().seconds / total, 0), 1)
        }
    }
}
