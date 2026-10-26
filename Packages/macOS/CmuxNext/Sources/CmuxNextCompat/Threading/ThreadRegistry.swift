public import Dispatch

extension DispatchQueue {
    /// Makes a queue like `DispatchQueue(label:qos:attributes:autoreleaseFrequency:target:)` whose label and QoS
    /// are a row of the thread registry (plans/cmux-next/threading-model.md, "Registered threads and queues").
    ///
    /// A queue states its QoS with `qos:`, or leaves it out and runs at its `target:`'s. In Debug and bench
    /// builds each queue made here is recorded in ``CheckedQueueLog/app``, which `debug.threads` lists under
    /// `queues`; a label ``ThreadRegistry/app`` does not declare, a QoS other than the declared one, or neither
    /// a QoS nor a target with one also logs a fault that names the call site. Release builds only make the queue.
    ///
    /// ```swift
    /// let queue = DispatchQueue.checked(label: "com.cmuxterm.next.settings.watcher", qos: .utility)
    /// ```
    ///
    /// - Parameters:
    ///   - label: The queue's label, as the registry declares it.
    ///   - qos: The queue's QoS, as the registry declares it; leave it out to run at `target`'s.
    ///   - attributes: The queue's attributes.
    ///   - autoreleaseFrequency: How often the queue drains its autorelease pool.
    ///   - target: The queue this one targets.
    ///   - fileID: The calling code's `#fileID`.
    ///   - line: The calling code's `#line`.
    /// - Returns: The new queue.
    public static func checked(
        label: String,
        qos: DispatchQoS = .unspecified,
        attributes: Attributes = [],
        autoreleaseFrequency: AutoreleaseFrequency = .inherit,
        target: DispatchQueue? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) -> DispatchQueue {
        #if DEBUG || CMUX_BENCH_HOOKS
        CheckedQueueLog.app.record(label: label, qos: ThreadQoS(qos.qosClass), target: target, site: "\(fileID):\(line)",
                                   registry: .app)
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

/// One declared thread or queue: its name (a pthread name, a dispatch label or an OperationQueue name), the QoS
/// it runs at, and who creates it.
public struct ThreadDeclaration: Sendable, Hashable {
    /// Who creates the thread.
    public enum Origin: String, Sendable {
        /// cmux code.
        case cmux
        /// A library cmux links (Ghostty, CEF, WebKit, Sentry): the row records the QoS the library uses.
        case library
    }

    /// How a row's name matches a thread's name or the label of the queue the thread drains.
    public enum Match: String, Sendable {
        /// The whole name.
        case exact
        /// The fixed start of an interpolated name (`com.cmuxterm.next.control.<id>`).
        case prefix
        /// An `OperationQueue`'s `name`: Foundation runs each operation on a dispatch queue labelled
        /// `<name> :: NSOperation 0x... (QOS: ...)`, so the label is the name or the name, a space and more.
        case operationQueue = "operation-queue"
    }

    /// The full name, or the fixed start of the name for a ``Match/prefix`` row.
    public var name: String
    /// How ``name`` matches.
    public var match: Match
    /// The QoS the thread's requested QoS must equal.
    public var qos: ThreadQoS
    /// Who creates the thread.
    public var origin: Origin

    /// Whether ``name`` is the start of an interpolated name.
    public var isPrefix: Bool { match == .prefix }

    /// Makes a declaration.
    ///
    /// - Parameters:
    ///   - name: The full name, or its fixed start for a prefix row.
    ///   - match: How `name` matches a thread name or a queue label.
    ///   - qos: The declared QoS.
    ///   - origin: Who creates the thread.
    public init(_ name: String, match: Match = .exact, qos: ThreadQoS, origin: Origin = .cmux) {
        self.name = name
        self.match = match
        self.qos = qos
        self.origin = origin
    }

    /// Whether `candidate` (a thread name or a queue label) is this row's thread.
    public func matches(_ candidate: String) -> Bool {
        switch match {
        case .exact: candidate == name
        case .prefix: candidate.hasPrefix(name)
        case .operationQueue: candidate == name || candidate.hasPrefix(name + " ")
        }
    }
}

/// The declared threads and queues of the app process: what `debug.threads` compares
/// each live thread's requested QoS with, and what ``DispatchQueue/checked(label:qos:attributes:autoreleaseFrequency:target:fileID:line:)``
/// checks a new queue against. Chrome names every thread it starts and gives each its thread type
/// (base/threading/platform_thread.h, `ThreadType`); this is the same list, written down once.
public struct ThreadRegistry: Sendable {
    /// The rows, in no particular order.
    public let rows: [ThreadDeclaration]
    /// The name starts only cmux code uses: a thread or queue with one and no row is an undeclared cmux thread
    /// (`debug.threads` `undeclared_cmux`), not a system or library thread.
    public let ownPrefixes: [String]

    /// Makes a registry over `rows` (tests; the app uses ``app``).
    ///
    /// - Parameters:
    ///   - rows: The declared threads and queues.
    ///   - ownPrefixes: The name starts only cmux code uses.
    public init(rows: [ThreadDeclaration], ownPrefixes: [String] = []) {
        self.rows = rows
        self.ownPrefixes = ownPrefixes
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

    /// Whether `name` (a thread name or a queue label) starts with one of ``ownPrefixes``.
    public func isOwn(_ name: String) -> Bool {
        ownPrefixes.contains { name.hasPrefix($0) }
    }

    /// What is wrong with a new queue: its label is not declared, it states neither a QoS nor a target with one,
    /// or the QoS it runs at is not the declared one; nil when the queue matches its row.
    ///
    /// - Parameters:
    ///   - label: The queue's label.
    ///   - qos: The QoS the queue states; unspecified when it runs at its target's.
    ///   - targetQoS: The target's QoS; nil with no target.
    func problem(label: String, qos: ThreadQoS, targetQoS: ThreadQoS? = nil) -> String? {
        guard let row = declaration(for: label) else {
            return "queue \(label) is not in threading-model.md's registered threads (ThreadRegistry.app)"
        }
        let runs = Self.effectiveQoS(qos, targetQoS: targetQoS)
        guard runs != .unspecified else {
            return "queue \(label) states neither qos: nor a target with a QoS; ThreadRegistry.app declares \(row.qos.rawValue)"
        }
        guard row.qos == runs else {
            let source = qos == .unspecified ? "its target's" : "stated"
            return "queue \(label) runs at \(runs.rawValue) (\(source)); ThreadRegistry.app declares \(row.qos.rawValue)"
        }
        return nil
    }

    /// The QoS a queue runs at: the one it states, else its target's.
    static func effectiveQoS(_ qos: ThreadQoS, targetQoS: ThreadQoS?) -> ThreadQoS {
        qos == .unspecified ? targetQoS ?? .unspecified : qos
    }
}

extension ThreadRegistry {
    /// The main thread's row name (the main queue's label): `debug.threads` matches the main thread by its id,
    /// since its pthread name is empty and it carries the label only while it drains the main queue.
    public static let mainThreadName = "com.apple.main-thread"

    /// The app process's rows: plans/cmux-next/threading-model.md "Registered threads and queues", each at the
    /// QoS the doc writes after it (chrome-parity p02-threads section C's tiers); ThreadsControlTests compares
    /// the two.
    public static let app = ThreadRegistry(rows: [
        // Main and frame.
        ThreadDeclaration(ThreadRegistry.mainThreadName, qos: .userInteractive),
        ThreadDeclaration("cmux-next main-thread watchdog", qos: .userInteractive),
        ThreadDeclaration("cmux-next quit deadline", qos: .userInteractive),
        ThreadDeclaration("cmux-next crash deadline", qos: .userInteractive),
        // Daemon.
        ThreadDeclaration("cmux-tui reader ", match: .prefix, qos: .userInteractive),
        ThreadDeclaration("com.cmuxterm.next.daemon.write", qos: .userInteractive),
        ThreadDeclaration("com.cmuxterm.next.daemon.path.", match: .prefix, qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.daemon.exit.", match: .prefix, qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.retry-wake", qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.process-progress", qos: .utility),
        // Control (automation).
        ThreadDeclaration("com.cmuxterm.next.control.accept", qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.control.", match: .prefix, qos: .utility),
        // Terminal (the key echo path).
        ThreadDeclaration("com.cmuxterm.next.terminal.output", qos: .userInteractive),
        ThreadDeclaration("com.cmuxterm.next.localpty.read", qos: .userInteractive),
        ThreadDeclaration("com.cmuxterm.next.localpty.write", qos: .userInteractive),
        // Settings and files (watchers are utility).
        ThreadDeclaration("com.cmuxterm.next.settings.watcher", qos: .utility),
        ThreadDeclaration("cmux.files.fsevents", qos: .utility),
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
        ThreadDeclaration("com.cmuxterm.chromium-runtime.download", match: .operationQueue, qos: .utility),
        ThreadDeclaration("cmux-next webkit setup probe", qos: .utility),
        // Agents.
        ThreadDeclaration("com.cmuxterm.app.next.agent-pane.prompt-journal", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.agent-pane.inbound", qos: .userInitiated),
        ThreadDeclaration("cmux.next.agent-pane.acpmux-exit.", match: .prefix, qos: .utility),
        ThreadDeclaration("cmux.next.agent-pane.acpmux-log-progress", qos: .utility),
        ThreadDeclaration("cmux.next.agent-pane.acpmux-launch-reap.", match: .prefix, qos: .utility),
        ThreadDeclaration("cmux.next.agent-pane.acpmux-status", qos: .utility),
        ThreadDeclaration("cmux.acpmux.checked-line", qos: .utility),
        ThreadDeclaration("cmux.agent-activity.socket", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.chief-settle", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.tasks.socket", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.app.next.agent-pane.socket", match: .operationQueue, qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.app.next.agent-pane.pull-request", match: .operationQueue, qos: .utility),
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
        ThreadDeclaration("cmux.home.promised-files", match: .operationQueue, qos: .userInitiated),
    ], ownPrefixes: ["com.cmuxterm.", "com.cmux.", "cmux", "cua-", "debug."])
}
