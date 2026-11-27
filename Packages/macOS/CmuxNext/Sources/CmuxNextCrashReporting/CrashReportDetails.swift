public import Foundation

/// The detail lines of a crash issue report: macOS's report of the crash
/// (exception type, codes and faulting address, termination, the crashed
/// thread and its top frames, the uptime, the file name) and the run's last
/// ``CrashContext`` (open counts, focused pane kind, browser engine, memory,
/// last actions).
///
/// Every line is scrubbed of the home folder (`~`). Frames macOS left
/// unnamed (the app's own, stripped in release) are named by
/// ``ExecutableFunction`` when the report is of this build, else kept as
/// image offsets with the image's UUID, which its dSYM resolves.
///
/// ```swift
/// let details = CrashReportDetails(system: report, systemReportName: "cmux-2026-10-27-210342.ips",
///                                  context: previous.context, launched: previous.launched)
/// let summary = details.summary()        // "- Exception: …", "- Uptime: …"
/// let blocks = details.blocks(frames: 20, actions: 12)
/// ```
public nonisolated struct CrashReportDetails: Sendable {
    /// Names a frame of the app executable: its UUID, offset from the image header, and whether it
    /// is a return address. Nil when the UUID is not this build's.
    public typealias ExecutableFunction = @Sendable (_ uuid: String, _ imageOffset: UInt, _ returnAddress: Bool) -> (symbol: String, offset: UInt)?

    /// macOS's report of the crash, nil when none was found.
    public let system: SystemCrashReport?
    /// Its file name (`cmux-2026-10-27-210342.ips`).
    public let systemReportName: String?
    /// The run's last snapshot.
    public let context: CrashContext?
    /// When the run launched.
    public let launched: Date
    private let executableFunction: ExecutableFunction
    private let home: String

    /// - Parameters:
    ///   - system: macOS's report of the crash.
    ///   - systemReportName: Its file name.
    ///   - context: The run's last snapshot.
    ///   - launched: When the run launched (the uptime when macOS's report has none).
    ///   - executableFunction: Names the app's own frames; none by default.
    ///   - home: The home folder, written as `~`.
    public init(system: SystemCrashReport?, systemReportName: String?, context: CrashContext?, launched: Date,
                executableFunction: @escaping ExecutableFunction = { _, _, _ in nil }, home: String = NSHomeDirectory()) {
        self.system = system
        self.systemReportName = systemReportName
        self.context = context
        self.launched = launched
        self.executableFunction = executableFunction
        self.home = home
    }

    /// The bullet lines: exception, termination, crashed thread, uptime, open counts, focused pane,
    /// browser engine, memory and the report file.
    public func summary() -> [String] {
        var lines: [String] = []
        if let system {
            var exception = system.exceptionType
            if let signal = system.signal { exception += " (\(signal))" }
            if let subtype = system.exceptionSubtype { exception += ", \(subtype)" }
            if let codes = system.exceptionCodes { exception += ", codes \(codes)" }
            lines.append("- Exception: \(scrub(exception))")
            if let termination = system.termination { lines.append("- Termination: \(scrub(termination))") }
            lines.append("- Crashed thread: \(system.faultingThread)\(system.faultingQueue.map { " (\(scrub($0)))" } ?? "")")
        }
        if let uptime = system?.uptime {
            lines.append("- Uptime: \(Self.duration(uptime))")
        } else if let context {
            lines.append("- Uptime: at least \(Self.duration(context.updated.timeIntervalSince(launched)))")
        }
        if let context {
            let tabs = context.terminalTabs + context.browserTabs + context.otherTabs
            lines.append("- Open: \(context.windows) windows, \(context.workspaces) workspaces, \(tabs) tabs "
                + "(\(context.terminalTabs) terminal, \(context.browserTabs) browser, \(context.otherTabs) other)")
            lines.append("- Focused pane: \(context.focusedPane.map(scrub) ?? "none")")
            lines.append("- Browser engine: \(context.browserEngine.map(scrub) ?? "not started"), \(context.browserFailures) helper failures this run")
            lines.append("- Memory: \(context.footprintMegabytes) MB footprint\(age(of: context.updated))")
        }
        lines.append("- macOS crash report: \(systemReportName.map { "\($0) (Show Crash Log opens it)" } ?? "none found")")
        return lines
    }

    /// The crashed thread's top `frames` frames and the newest `actions` actions, each a titled
    /// block after a blank line; empty for a zero limit.
    ///
    /// - Parameters:
    ///   - frames: The most frames.
    ///   - actions: The most actions.
    public func blocks(frames frameLimit: Int, actions actionLimit: Int) -> [String] {
        var lines: [String] = []
        if let system, frameLimit > 0, !system.frames.isEmpty {
            let shown = system.frames.prefix(frameLimit)
            lines += ["", "Crashed thread \(system.faultingThread), top \(shown.count) of \(system.frames.count) frames:", "```"]
            lines += shown.enumerated().map { index, frame in self.frame(index, frame, in: system) }
            lines.append("```")
            if let note = unresolvedNote(shown, in: system) { lines.append(note) }
        }
        if let context, actionLimit > 0, !context.actions.isEmpty {
            lines += ["", "Last actions (newest first; the one running at the crash may be missing):"]
            lines += context.actions.prefix(actionLimit).map { "- \(scrub($0.id)) (\(scrub($0.entrypoint)))\(age(of: $0.at))" }
        }
        return lines
    }

    /// `0.4 s`, `42 s`, `3 min 5 s`, `1 h 46 min`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        if value < 10 { return String(format: "%.1f s", value) }
        let whole = Int(value.rounded())
        if whole < 60 { return "\(whole) s" }
        if whole < 3_600 { return "\(whole / 60) min \(whole % 60) s" }
        return "\(whole / 3_600) h \((whole % 3_600) / 60) min"
    }

    /// `, 4.2 s before the crash`, when macOS's report gave the crash time.
    private func age(of date: Date) -> String {
        guard let captured = system?.captured else { return "" }
        return ", \(Self.duration(captured.timeIntervalSince(date))) before the crash"
    }

    /// `5   cmux   PaneController.focus() + 120`: the report's symbol, else the app's own name,
    /// else the image offset.
    private func frame(_ index: Int, _ frame: SystemCrashReport.Frame, in report: SystemCrashReport) -> String {
        let image = report.images.indices.contains(frame.imageIndex) ? report.images[frame.imageIndex] : nil
        let name = image?.name ?? "???"
        let prefix = String(index).padding(toLength: 4, withPad: " ", startingAt: 0)
            + name.padding(toLength: max(name.count, 26), withPad: " ", startingAt: 0) + " "
        if let symbol = frame.symbol {
            return prefix + short(symbol) + (frame.symbolLocation.map { " + \($0)" } ?? "")
        }
        if let image, let found = executableFunction(image.uuid, UInt(frame.imageOffset), index > 0) {
            return prefix + short(found.symbol) + " + \(found.offset)"
        }
        return prefix + "0x" + String(frame.imageOffset, radix: 16)
    }

    /// Names the images of frames left as offsets, so they resolve against that build's dSYM.
    private func unresolvedNote(_ frames: ArraySlice<SystemCrashReport.Frame>, in report: SystemCrashReport) -> String? {
        let unresolved = Set(frames.compactMap { frame -> Int? in
            guard frame.symbol == nil, report.images.indices.contains(frame.imageIndex) else { return nil }
            let image = report.images[frame.imageIndex]
            return executableFunction(image.uuid, UInt(frame.imageOffset), true) == nil ? frame.imageIndex : nil
        })
        guard !unresolved.isEmpty else { return nil }
        let images = unresolved.sorted().map { "\(report.images[$0].name) \(report.images[$0].uuid.uppercased())" }
        return "Offsets only (another build, or no symbols): " + images.joined(separator: ", ")
    }

    /// The home folder as `~`; a long generic closure name cut to one readable line.
    private func short(_ symbol: String) -> String {
        let clean = scrub(symbol)
        return clean.count > 140 ? String(clean.prefix(139)) + "…" : clean
    }

    private func scrub(_ text: String) -> String {
        home.isEmpty ? text : text.replacingOccurrences(of: home, with: "~")
    }
}
