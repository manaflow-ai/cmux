import CmuxNextCompat
public import Foundation
import CmuxNextWakeups

/// What ``SystemNowPlaying`` asks the app that plays to do.
public nonisolated enum SystemNowPlayingCommand: Equatable, Sendable {
    case togglePlayPause
    case next
    case previous
    /// Moves to this many seconds in.
    case seek(TimeInterval)

    /// The adapter's arguments: `send` takes MediaRemote's command ids
    /// (2 toggle, 4 next, 5 previous), `seek` microseconds.
    var arguments: [String] {
        switch self {
        case .togglePlayPause: ["send", "2"]
        case .next: ["send", "4"]
        case .previous: ["send", "5"]
        case .seek(let seconds): ["seek", String(Int64((max(0, seconds) * 1_000_000).rounded()))]
        }
    }
}

/// Reads and drives macOS Now Playing for ``SystemNowPlaying``: the app's
/// adapter process, or a fake in tests.
@MainActor
public protocol SystemNowPlayingAdapter: AnyObject {
    /// Starts streaming; each data line, decoded off the main actor, goes to `onUpdate` on it.
    func start(onUpdate: @escaping @MainActor (SystemNowPlayingFeed.Update) -> Void)
    func stop()
    func send(_ command: SystemNowPlayingCommand)
}

/// macOS Now Playing through ungive/mediaremote-adapter (BSD-3-Clause). Since
/// macOS 15.4 only Apple-signed processes may read MediaRemote, so
/// `/usr/bin/perl` loads the adapter framework bundled with cmux and prints
/// each change as a JSON line. One `stream` process runs while the card
/// shows; its pipe wakes the app only when Now Playing changes, and its lines
/// are decoded on the pipe's queue. A stream that exits is started again after
/// a growing wait, and given up after a few quick exits in a row (an adapter
/// macOS no longer allows). Controls run one short `send` or `seek` process
/// each.
///
/// The stream never outlives cmux: it runs under ``parentWatch``, a shell that
/// holds a pipe from cmux on its stdin and ends the adapter when that pipe
/// closes, which the kernel does however cmux exits (a quit or a crash), so it
/// needs no quit hook of its own.
public final class MediaRemoteAdapterProcess: SystemNowPlayingAdapter {
    /// Spawns and stops the adapter's children off the main thread, in call order (a fork can take hundreds of ms).
    private let launcher = ProcessLauncher(label: "com.cmuxterm.next.now-playing", priority: .userVisible)
    public let script: URL
    public let framework: URL
    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")
    private var process: Process?
    /// The write end of the stream's stdin: open while cmux lives, so the watch shell waits.
    private var lifeline: Pipe?
    private var onUpdate: (@MainActor (SystemNowPlayingFeed.Update) -> Void)?
    /// Bumped by each launch, so a late line or exit of an earlier stream is ignored.
    private var run = 0
    /// Exits in a row that came soon after their start.
    private var quickExits = 0
    private let restart = DemandTimer(owner: "now-playing.adapter-restart")
    static let quickExit: TimeInterval = 10
    static let maximumQuickExits = 4
    static let streamArguments = ["stream", "--micros", "--debounce=150"]

    /// Runs `"$0" "$@"` (the adapter) and ends it when stdin reaches end of file, which happens
    /// when the process that holds the pipe's write end (cmux) exits, however it exits. SIGTERM
    /// (``stop()``) ends it too, also one that arrives before the adapter started (the trap is set
    /// first). The adapter's own exit ends the shell with its status, so a stream that dies is seen
    /// and restarted. `read` is a builtin: the watch is no extra process. cmux keeps its pipe ends
    /// close-on-exec, so no other process it spawns holds the pipe open.
    static let parentWatch = """
        exec 3<&0
        child= watch=
        trap '[ -n "$child" ] && kill "$child" 2>/dev/null; [ -n "$watch" ] && kill "$watch" 2>/dev/null; exit 143' TERM
        "$0" "$@" </dev/null &
        child=$!
        { while read -r _ <&3; do :; done; kill "$child" 2>/dev/null; } &
        watch=$!
        wait "$child"
        status=$?
        kill "$watch" 2>/dev/null
        exit "$status"
        """

    public init(script: URL, framework: URL) {
        self.script = script
        self.framework = framework
    }

    /// The adapter cmux bundles: the script in Resources/MediaRemoteAdapter and
    /// the framework in Frameworks; nil when either is missing (a build without it).
    public static func bundled(in bundle: Bundle = .main) -> MediaRemoteAdapterProcess? {
        guard let script = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl", subdirectory: "MediaRemoteAdapter"),
              let framework = bundle.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
              FileManager.default.fileExists(atPath: framework.path) else { return nil }
        return MediaRemoteAdapterProcess(script: script, framework: framework)
    }

    /// `executable arguments…` under ``parentWatch``: what cmux launches for a stream.
    static func watched(_ executable: URL, _ arguments: [String]) -> (URL, [String]) {
        (URL(fileURLWithPath: "/bin/sh"), ["-c", parentWatch, executable.path] + arguments)
    }

    public func start(onUpdate: @escaping @MainActor (SystemNowPlayingFeed.Update) -> Void) {
        self.onUpdate = onUpdate
        quickExits = 0
        launch()
    }

    public func stop() {
        onUpdate = nil
        restart.cancel()
        let running = process
        process = nil
        running?.terminationHandler = nil
        (running?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if let running { launcher.terminate(running) }
        try? lifeline?.fileHandleForWriting.close()
        lifeline = nil
    }

    public func send(_ command: SystemNowPlayingCommand) {
        let once = Process()
        once.executableURL = Self.perl
        once.arguments = [script.path, framework.path] + command.arguments
        once.standardInput = FileHandle.nullDevice
        once.standardOutput = FileHandle.nullDevice
        once.standardError = FileHandle.nullDevice
        launcher.launch(once)
    }

    private func launch() {
        guard onUpdate != nil, process == nil else { return }
        run &+= 1
        let current = run
        let stream = Process()
        let (shell, arguments) = Self.watched(Self.perl, [script.path, framework.path] + Self.streamArguments)
        stream.executableURL = shell
        stream.arguments = arguments
        let stdin = Pipe()
        // Close-on-exec: only the stream gets the read end (as its stdin); a shell or helper cmux
        // spawns later must not inherit the write end and keep the pipe open past a crash.
        for handle in [stdin.fileHandleForWriting, stdin.fileHandleForReading] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        stream.standardInput = stdin
        stream.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        stream.standardOutput = stdout
        let splitter = AdapterLineSplitter()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data: Data
            switch handle.readReady() {
            case .bytes(let ready): data = ready
            case .retry: return
            case .end:
                handle.readabilityHandler = nil
                return
            }
            // Decoded here, on the pipe's queue: an artwork line is megabytes of JSON.
            let updates = splitter.append(data).compactMap(SystemNowPlayingFeed.Update.decode)
            guard !updates.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.run == current, self.process != nil, let onUpdate = self.onUpdate else { return }
                for update in updates { onUpdate(update) }
            }
        }
        let started = Date()
        stream.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.exited(run: current, after: Date().timeIntervalSince(started)) }
        }
        process = stream
        lifeline = stdin
        // The spawn runs off main; a launch failure clears this run's state back on main.
        launcher.launch(stream) { _ in
            stdout.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                guard let self, self.run == current else { return }
                self.process = nil
                try? self.lifeline?.fileHandleForWriting.close()
                self.lifeline = nil
            }
        }
    }

    /// Starts the stream again after a growing wait, unless it keeps exiting at once.
    private func exited(run exited: Int, after seconds: TimeInterval) {
        guard run == exited, process != nil else { return }
        process = nil
        try? lifeline?.fileHandleForWriting.close()
        lifeline = nil
        guard onUpdate != nil else { return }
        quickExits = seconds < Self.quickExit ? quickExits + 1 : 0
        guard quickExits <= Self.maximumQuickExits else { return }
        restart.schedule(after: .seconds(1 << min(quickExits, 6))) { @MainActor [weak self] in self?.launch() }
    }
}

/// Splits the adapter's stdout into lines; an artwork line can be a few megabytes.
nonisolated final class AdapterLineSplitter: Sendable {
    private let buffer = Mutex(Data())
    static let maximumLine = 16 << 20

    func append(_ data: Data) -> [Data] {
        buffer.withLock { buffer in
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(Data(buffer[buffer.startIndex..<newline]))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if buffer.count > Self.maximumLine { buffer.removeAll() }
            return lines
        }
    }
}
