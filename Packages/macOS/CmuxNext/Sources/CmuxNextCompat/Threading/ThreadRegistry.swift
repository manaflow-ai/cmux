public import Dispatch
#if DEBUG || CMUX_BENCH_HOOKS
internal import os
#endif

extension DispatchQueue {
    /// Makes a queue like `DispatchQueue(label:qos:attributes:autoreleaseFrequency:target:)` whose label and QoS
    /// are a row of the thread registry (plans/cmux-next/threading-model.md, "Registered threads and queues").
    ///
    /// In Debug and bench builds a label ``ThreadRegistry/app`` does not declare, or a QoS other than the
    /// declared one, logs a fault that names the call site, and `debug.threads` reports the queue's threads
    /// against that row. Release builds only make the queue.
    ///
    /// ```swift
    /// let queue = DispatchQueue.checked(label: "com.cmuxterm.next.settings.watcher", qos: .utility)
    /// ```
    ///
    /// - Parameters:
    ///   - label: The queue's label, as the registry declares it.
    ///   - qos: The queue's QoS, as the registry declares it.
    ///   - attributes: The queue's attributes.
    ///   - autoreleaseFrequency: How often the queue drains its autorelease pool.
    ///   - target: The queue this one targets.
    ///   - fileID: The calling code's `#fileID`.
    ///   - line: The calling code's `#line`.
    /// - Returns: The new queue.
    public static func checked(
        label: String,
        qos: DispatchQoS,
        attributes: Attributes = [],
        autoreleaseFrequency: AutoreleaseFrequency = .inherit,
        target: DispatchQueue? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) -> DispatchQueue {
        #if DEBUG || CMUX_BENCH_HOOKS
        if let problem = ThreadRegistry.app.problem(label: label, qos: ThreadQoS(qos.qosClass)) {
            let site = "\(fileID):\(line)"
            Logger(subsystem: "com.cmuxterm.app.next", category: "threads").fault("\(site, privacy: .public): \(problem, privacy: .public)")
        }
        #endif
        return DispatchQueue(label: label, qos: qos, attributes: attributes, autoreleaseFrequency: autoreleaseFrequency, target: target)
    }
}

/// A thread's requested quality of service, the kernel's `THREAD_QOS_*` tiers.
public enum ThreadQoS: String, Sendable, CaseIterable {
    case userInteractive = "user-interactive"
    case userInitiated = "user-initiated"
    case `default`
    case utility
    case background
    case maintenance
    case unspecified

    /// The QoS of a kernel tier (`THREAD_QOS_POLICY` `qos_tier`); nil for a value the kernel does not define.
    ///
    /// - Parameter kernelTier: `THREAD_QOS_UNSPECIFIED` (0) through `THREAD_QOS_USER_INTERACTIVE` (6).
    public init?(kernelTier: Int32) {
        switch kernelTier {
        case 0: self = .unspecified
        case 1: self = .maintenance
        case 2: self = .background
        case 3: self = .utility
        case 4: self = .default
        case 5: self = .userInitiated
        case 6: self = .userInteractive
        default: return nil
        }
    }

    /// The QoS of a dispatch QoS class.
    ///
    /// - Parameter qosClass: The dispatch class.
    public init(_ qosClass: DispatchQoS.QoSClass) {
        switch qosClass {
        case .userInteractive: self = .userInteractive
        case .userInitiated: self = .userInitiated
        case .default: self = .default
        case .utility: self = .utility
        case .background: self = .background
        case .unspecified: self = .unspecified
        @unknown default: self = .unspecified
        }
    }
}

/// One declared thread or queue: its name (a pthread name or a dispatch label), the QoS it runs at, and
/// who creates it.
public struct ThreadDeclaration: Sendable, Hashable {
    /// Who creates the thread.
    public enum Origin: String, Sendable {
        /// cmux code.
        case cmux
        /// A library cmux links (Ghostty, CEF, WebKit, Sentry): the row records the QoS the library uses.
        case library
    }

    /// The full name, or the fixed start of the name when ``isPrefix``.
    public var name: String
    /// Whether ``name`` is the start of an interpolated name (`com.cmuxterm.next.control.<id>`).
    public var isPrefix: Bool
    /// The QoS the thread's requested QoS must equal.
    public var qos: ThreadQoS
    /// Who creates the thread.
    public var origin: Origin

    /// Makes a declaration.
    ///
    /// - Parameters:
    ///   - name: The full name, or its fixed start when `prefix`.
    ///   - prefix: Whether `name` is the start of an interpolated name.
    ///   - qos: The declared QoS.
    ///   - origin: Who creates the thread.
    public init(_ name: String, prefix: Bool = false, qos: ThreadQoS, origin: Origin = .cmux) {
        self.name = name
        self.isPrefix = prefix
        self.qos = qos
        self.origin = origin
    }

    /// Whether `candidate` (a thread name or a queue label) is this row's thread.
    public func matches(_ candidate: String) -> Bool {
        isPrefix ? candidate.hasPrefix(name) : candidate == name
    }
}

/// The declared threads and queues of the app process: what `debug.threads` compares
/// each live thread's requested QoS with, and what ``DispatchQueue/checked(label:qos:attributes:autoreleaseFrequency:target:fileID:line:)``
/// checks a new queue against. Chrome names every thread it starts and gives each its thread type
/// (base/threading/platform_thread.h, `ThreadType`); this is the same list, written down once.
public struct ThreadRegistry: Sendable {
    /// The rows, in no particular order.
    public let rows: [ThreadDeclaration]

    /// Makes a registry over `rows` (tests; the app uses ``app``).
    public init(rows: [ThreadDeclaration]) {
        self.rows = rows
    }

    /// The row for a thread name or queue label: an exact row first, else the longest matching prefix; nil when
    /// nothing declares it.
    public func declaration(for name: String) -> ThreadDeclaration? {
        guard !name.isEmpty else { return nil }
        var best: ThreadDeclaration?
        for row in rows where row.matches(name) {
            if !row.isPrefix { return row }
            if row.name.count > best?.name.count ?? -1 { best = row }
        }
        return best
    }

    /// What is wrong with a new queue: its label is not declared, or its QoS is not the declared one; nil when
    /// the queue matches its row.
    func problem(label: String, qos: ThreadQoS) -> String? {
        guard let row = declaration(for: label) else {
            return "queue \(label) is not in threading-model.md's registered threads (ThreadRegistry.app)"
        }
        guard row.qos == qos else {
            return "queue \(label) is \(qos.rawValue); ThreadRegistry.app declares \(row.qos.rawValue)"
        }
        return nil
    }
}

extension ThreadRegistry {
    /// The main thread's row name (the main queue's label): `debug.threads` matches the main thread by its id,
    /// since its pthread name is empty and it carries the label only while it drains the main queue.
    public static let mainThreadName = "com.apple.main-thread"

    /// The app process's rows: plans/cmux-next/threading-model.md "Registered threads and queues", each at the
    /// QoS its owner row and the QoS design (chrome-parity p02-threads, section C) give it.
    public static let app = ThreadRegistry(rows: [
        // Main and frame.
        ThreadDeclaration(ThreadRegistry.mainThreadName, qos: .userInteractive),
        ThreadDeclaration("cmux-next main-thread watchdog", qos: .userInteractive),
        ThreadDeclaration("cmux-next quit deadline", qos: .userInteractive),
        ThreadDeclaration("cmux-next crash deadline", qos: .userInteractive),
        // Daemon.
        ThreadDeclaration("cmux-tui reader ", prefix: true, qos: .userInteractive),
        ThreadDeclaration("com.cmuxterm.next.daemon.write", qos: .userInteractive),
        ThreadDeclaration("com.cmuxterm.next.daemon.path.", prefix: true, qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.daemon.exit.", prefix: true, qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.retry-wake", qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.process-progress", qos: .utility),
        // Control (automation).
        ThreadDeclaration("com.cmuxterm.next.control.accept", qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.control.", prefix: true, qos: .utility),
        // Terminal (the key echo path).
        ThreadDeclaration("com.cmuxterm.next.terminal.output", qos: .userInteractive),
        ThreadDeclaration("com.cmuxterm.next.localpty.read", qos: .userInteractive),
        ThreadDeclaration("com.cmuxterm.next.localpty.write", qos: .userInteractive),
        // Settings and files.
        ThreadDeclaration("com.cmuxterm.next.settings.watcher", qos: .utility),
        ThreadDeclaration("cmux.files.fsevents", qos: .userInitiated),
        ThreadDeclaration("cmux.files.tree-fsevents", qos: .utility),
        ThreadDeclaration("com.cmuxterm.home.cache", qos: .userInitiated),
        // Remote and mobile.
        ThreadDeclaration("com.cmuxterm.next.remote-localhost", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.cloud-browser-proxy", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.remote-fetch", qos: .userInitiated),
        ThreadDeclaration("cmux.remote-view.render", qos: .userInteractive),
        ThreadDeclaration("cmux.remote-view.rd-transport", qos: .userInitiated),
        ThreadDeclaration("cmux.remote-view.mock-host", qos: .utility),
        ThreadDeclaration("cmux.next.mobile.unix-lane", qos: .userInitiated),
        // Browser.
        ThreadDeclaration("com.cmuxterm.next.browser-host.provider.write", qos: .userInitiated),
        ThreadDeclaration("cmux browser-host provider reader", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.chromium-host.read", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.chromium-host.exit", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.app.next.cef-children", qos: .utility),
        ThreadDeclaration("com.cmuxterm.import-history-sync", qos: .utility),
        ThreadDeclaration("com.cmuxterm.chromium-runtime.download", qos: .utility),
        ThreadDeclaration("cmux-next webkit setup probe", qos: .utility),
        // Agents.
        ThreadDeclaration("com.cmuxterm.app.next.agent-pane.prompt-journal", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.agent-pane.inbound", qos: .userInitiated),
        ThreadDeclaration("cmux.next.agent-pane.acpmux-exit.", prefix: true, qos: .utility),
        ThreadDeclaration("cmux.next.agent-pane.acpmux-log-progress", qos: .utility),
        ThreadDeclaration("cmux.next.agent-pane.acpmux-launch-reap.", prefix: true, qos: .utility),
        ThreadDeclaration("cmux.next.agent-pane.acpmux-status", qos: .utility),
        ThreadDeclaration("cmux.acpmux.checked-line", qos: .utility),
        ThreadDeclaration("cmux.agent-activity.socket", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.chief-settle", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.tasks.socket", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.app.next.agent-pane.socket", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.app.next.agent-pane.pull-request", qos: .utility),
        ThreadDeclaration("cua-helper-v2-reap", qos: .utility),
        ThreadDeclaration("cua-helper-v2-stdout", qos: .utility),
        // Diagnostics.
        ThreadDeclaration("cmux-next.hang-episodes", qos: .utility),
        ThreadDeclaration("cmux-next.hang-episodes.symbols", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.run-marker", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.crash-forwarder", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.owner-panic-forwarder", qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.typing-probe", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.blocking-drain", qos: .utility),
        ThreadDeclaration("com.cmux.host-pressure", qos: .utility),
        ThreadDeclaration("debug.window_record", qos: .userInitiated),
        // Launch and misc.
        ThreadDeclaration("cmux-next resource bundle warm-up", qos: .userInitiated),
        ThreadDeclaration("cmux-next launch warm-up", qos: .userInitiated),
        ThreadDeclaration("cmux.updates.network", qos: .utility),
        ThreadDeclaration("cmux.home.fixture.video", qos: .utility),
        ThreadDeclaration("cmux.home.promised-files", qos: .userInitiated),
    ])
}
