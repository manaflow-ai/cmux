import OSLog

/// A terminal shown again reports what it shows (``TerminalRevealReport``): to the log, to the delegate (the App's
/// crash-telemetry breadcrumbs), and once more if its pane still shows nothing ``TerminalBlankWatch/limit`` later, or
/// drew and still shows its frames at another scale than Ghostty draws at.
/// Numbers only, no terminal text. The Nov 4 blank-then-tiny pane left no trace to tell a discarded frame from a
/// scale mismatch; these lines are that trace.
extension TerminalSession {
    private static let revealLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "terminal.reveal")

    /// `view` draws again while shown; `saved` is what became of the frame it kept while hidden.
    func surfaceRevealed(_ view: TerminalSurfaceView, saved: TerminalRevealReport.SavedFrame) {
        guard view === surfaceView, !isClosed else { return }
        let report = view.revealReport(saved: saved)
        let message = report.message
        if !report.isSuspect {
            Self.revealLogger.info("revealed \(message, privacy: .public)")
        } else {
            Self.revealLogger.error("revealed \(message, privacy: .public)")
        }
        delegate?.terminalSession(self, revealed: report)
        // Ghostty's present callback counts the frames the layer shows: one since the reveal means the pane drew.
        let presents = view.bridge.takeUnretainedValue().presents, atReveal = presents.count
        blankWatch.watch(probe: { [weak self, weak view] in
            guard let self, let view, view === self.surfaceView, !self.isClosed, view.isShown, view.pause == nil else { return nil }
            return view.revealReport(saved: saved, framesSinceReveal: presents.count - atReveal)
        }, onBlank: { [weak self] report in
            guard let self else { return }
            let message = report.message, limit = "\(TerminalBlankWatch.limit)"
            Self.revealLogger.error("blank \(limit, privacy: .public) after reveal: \(message, privacy: .public)")
            self.delegate?.terminalSession(self, blankAfterReveal: report)
        }, onScaleMismatch: { [weak self] report in
            guard let self else { return }
            let message = report.message, limit = "\(TerminalBlankWatch.limit)"
            Self.revealLogger.error("scales disagree \(limit, privacy: .public) after reveal: \(message, privacy: .public)")
            self.delegate?.terminalSession(self, revealed: report)
        })
    }

    /// `view` stopped drawing (hidden, parked, occluded): no blank check for it.
    func surfaceHidden(_ view: TerminalSurfaceView) {
        guard view === surfaceView else { return }
        blankWatch.cancel()
    }
}

extension TerminalSurfaceView {
    /// What this terminal shows now (``TerminalRevealReport``); `saved` is what became of its kept frame, and
    /// `framesSinceReveal` the frames Ghostty showed on the layer since the reveal.
    func revealReport(saved: TerminalRevealReport.SavedFrame, framesSinceReveal: UInt64 = 0) -> TerminalRevealReport {
        let fontScale = bridge.takeUnretainedValue().fontScale
        return TerminalRevealReport(
            contentScale: appliedContentScale?.width,
            layerScale: layer?.contentsScale,
            windowScale: window.map { backingScaleOverride ?? $0.backingScaleFactor },
            savedFrame: saved,
            holdingFrame: session?.frameHold.isHolding ?? false,
            hasFrame: layer?.contents != nil,
            fontPoints: GhosttyRuntime.shared.configuredFontSize.map { $0 * (fontScale ?? 1) },
            fontScale: fontScale,
            viewSize: bounds.size,
            framesSinceReveal: framesSinceReveal)
    }
}
