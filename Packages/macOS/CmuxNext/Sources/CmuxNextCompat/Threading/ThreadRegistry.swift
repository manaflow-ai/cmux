public import Dispatch

extension DispatchQueue {
    /// Makes a queue like `DispatchQueue(label:qos:attributes:autoreleaseFrequency:target:)` whose label and QoS
    /// are a row of the thread registry (plans/cmux-next/threading-model.md, "Registered threads and queues").
    ///
    /// A queue states its QoS with `qos:`, or leaves it out and runs at its `target:`'s. In Debug and bench
    /// builds each queue made here is recorded in ``CheckedQueueLog/app``, which `debug.threads` lists under
    /// `queues`; a label ``ThreadRegistry/app`` does not declare, a QoS its row does not allow, or neither
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
        recordChecked(label: label, qos: qos, target: target, fileID: fileID, line: line)
        return DispatchQueue(label: label, qos: qos, attributes: attributes, autoreleaseFrequency: autoreleaseFrequency, target: target)
    }

    /// Makes a serial queue like `DispatchSerialQueue(label:qos:autoreleaseFrequency:target:)`, checked and recorded
    /// as ``checked(label:qos:attributes:autoreleaseFrequency:target:fileID:line:)`` does: the shape an actor's
    /// custom executor needs (`asUnownedSerialExecutor()`).
    ///
    /// ```swift
    /// private nonisolated let queue = DispatchQueue.checkedSerial(label: "cmux.remote-view.render", qos: .userInteractive)
    /// ```
    ///
    /// - Parameters:
    ///   - label: The queue's label, as the registry declares it.
    ///   - qos: The queue's QoS, as the registry declares it; leave it out to run at `target`'s.
    ///   - autoreleaseFrequency: How often the queue drains its autorelease pool.
    ///   - target: The queue this one targets.
    ///   - fileID: The calling code's `#fileID`.
    ///   - line: The calling code's `#line`.
    /// - Returns: The new serial queue.
    public static func checkedSerial(
        label: String,
        qos: DispatchQoS = .unspecified,
        autoreleaseFrequency: AutoreleaseFrequency = .inherit,
        target: DispatchQueue? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) -> DispatchSerialQueue {
        recordChecked(label: label, qos: qos, target: target, fileID: fileID, line: line)
        return DispatchSerialQueue(label: label, qos: qos, autoreleaseFrequency: autoreleaseFrequency, target: target)
    }

    private static func recordChecked(label: String, qos: DispatchQoS, target: DispatchQueue?, fileID: StaticString, line: UInt) {
        #if DEBUG || CMUX_BENCH_HOOKS
        CheckedQueueLog.app.record(label: label, qos: ThreadQoS(qos.qosClass), target: target, site: "\(fileID):\(line)",
                                   registry: .app)
        #endif
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
        /// A library cmux links (GhosttyKit, CEF, WebKit, Sentry, iroh, WebRTC): the row records the QoS the
        /// library uses.
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

    /// The QoS a row's threads ask for. Chrome gives every thread one `ThreadType` and maps it to a QoS
    /// (base/threading/platform_thread_apple.mm); a cmux row is one tier the same way, and the other cases say who
    /// else picks the tier.
    public enum Policy: Sendable, Hashable {
        /// One QoS in every state.
        case fixed(ThreadQoS)
        /// The QoS follows the surface the thread works for: focused, visible but not focused, and hidden or
        /// occluded (ghostty-next src/renderer/Thread.zig `setQosClass`).
        case byVisibility(focused: ThreadQoS, visible: ThreadQoS, hidden: ThreadQoS)
        /// Each item, run or caller states the QoS (a lane slot, a process run, a child launcher): any tier below
        /// user-interactive, which only the closed list in threading-model.md may use.
        case perItem
        /// The library picks each thread's QoS from its own table (Chromium's `ThreadType`): any tier.
        case setByLibrary

        /// A Ghostty surface's threads: user-interactive focused, user-initiated visible, utility hidden.
        public static let surfaceVisibility = Policy.byVisibility(focused: .userInteractive, visible: .userInitiated, hidden: .utility)

        /// The tiers a thread of the row may ask for, highest first.
        public var tiers: [ThreadQoS] {
            switch self {
            case .fixed(let qos): [qos]
            case .byVisibility(let focused, let visible, let hidden): [focused, visible, hidden]
            case .perItem: [.userInitiated, .default, .utility, .background, .maintenance]
            case .setByLibrary: ThreadQoS.allCases
            }
        }

        /// The tier a thread of the row asks for while what it works for is hidden: a fixed row's one QoS, a
        /// by-visibility row's hidden tier; nil when each item or the library picks.
        public var hidden: ThreadQoS? {
            switch self {
            case .fixed(let qos): qos
            case .byVisibility(_, _, let hidden): hidden
            case .perItem, .setByLibrary: nil
            }
        }

        /// The policy as threading-model.md and `debug.threads` write it: a fixed row's QoS, else `by-visibility`,
        /// `per-item` or `set-by-library`.
        public var name: String {
            switch self {
            case .fixed(let qos): qos.rawValue
            case .byVisibility: "by-visibility"
            case .perItem: "per-item"
            case .setByLibrary: "set-by-library"
            }
        }

        /// Whether a thread of the row may ask for `requested`.
        public func allows(_ requested: ThreadQoS) -> Bool {
            tiers.contains(requested)
        }
    }

    /// The full name, or the fixed start of the name for a ``Match/prefix`` row.
    public var name: String
    /// How ``name`` matches.
    public var match: Match
    /// The QoS the thread's requested QoS must be one of.
    public var policy: Policy
    /// Who creates the thread.
    public var origin: Origin
    /// The library that starts the thread (`GhosttyKit`, `CEF`, ...); nil for a cmux row.
    public var library: String?

    /// Whether ``name`` is the start of an interpolated name.
    public var isPrefix: Bool { match == .prefix }

    /// Makes a declaration of one QoS.
    ///
    /// - Parameters:
    ///   - name: The full name, or its fixed start for a prefix row.
    ///   - match: How `name` matches a thread name or a queue label.
    ///   - qos: The declared QoS.
    ///   - origin: Who creates the thread.
    public init(_ name: String, match: Match = .exact, qos: ThreadQoS, origin: Origin = .cmux) {
        self.init(name, match: match, policy: .fixed(qos), origin: origin)
    }

    /// Makes a declaration.
    ///
    /// - Parameters:
    ///   - name: The full name, or its fixed start for a prefix row.
    ///   - match: How `name` matches a thread name or a queue label.
    ///   - policy: The QoS the thread may ask for.
    ///   - origin: Who creates the thread.
    ///   - library: The library that starts the thread, for a library row.
    public init(_ name: String, match: Match = .exact, policy: Policy, origin: Origin = .cmux, library: String? = nil) {
        self.name = name
        self.match = match
        self.policy = policy
        self.origin = origin
        self.library = library
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

/// The names a linked library gives its threads: a thread no row declares whose name or queue label is in one is
/// that library's thread with no row (`debug.threads` `undeclared_library`), not a system thread. A name space is
/// wider than the library's rows, so a thread the library adds later still counts.
public struct LibraryNamespace: Sendable, Hashable {
    /// How a name space matches a thread name or a queue label.
    public enum Pattern: Sendable, Hashable {
        /// Names that start with the text (`Chrome`, `io.sentry`).
        case prefix(String)
        /// Names that contain the text anywhere (WebRTC's `<name>_thread 0x<pointer>`).
        case contains(String)
    }

    /// The library (`CEF`, `WebRTC`, ...), as its rows name it.
    public var library: String
    /// The names the library uses.
    public var pattern: Pattern

    /// Makes a name space.
    ///
    /// - Parameters:
    ///   - library: The library, as its rows name it.
    ///   - pattern: The names the library uses.
    public init(_ library: String, _ pattern: Pattern) {
        self.library = library
        self.pattern = pattern
    }

    /// Whether `candidate` (a thread name or a queue label) is in the name space.
    public func matches(_ candidate: String) -> Bool {
        switch pattern {
        case .prefix(let text): candidate.hasPrefix(text)
        case .contains(let text): candidate.contains(text)
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
    /// The names the linked libraries use: a thread or queue in one and with no row is a library thread with no row
    /// (`debug.threads` `undeclared_library`), not a system thread.
    public let libraryNamespaces: [LibraryNamespace]

    /// Makes a registry over `rows` (tests; the app uses ``app``).
    ///
    /// - Parameters:
    ///   - rows: The declared threads and queues.
    ///   - ownPrefixes: The name starts only cmux code uses.
    ///   - libraryNamespaces: The names the linked libraries use.
    public init(rows: [ThreadDeclaration], ownPrefixes: [String] = [], libraryNamespaces: [LibraryNamespace] = []) {
        self.rows = rows
        self.ownPrefixes = ownPrefixes
        self.libraryNamespaces = libraryNamespaces
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

    /// The library whose name space holds `name` (a thread name or a queue label); nil when none does.
    public func namespaceLibrary(of name: String) -> String? {
        guard !name.isEmpty else { return nil }
        return libraryNamespaces.first { $0.matches(name) }?.library
    }

    /// What is wrong with a new queue: its label is not declared, it states neither a QoS nor a target with one,
    /// or its row does not allow the QoS it runs at; nil when the queue matches its row.
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
            return "queue \(label) states neither qos: nor a target with a QoS; ThreadRegistry.app declares \(row.policy.name)"
        }
        guard row.policy.allows(runs) else {
            let source = qos == .unspecified ? "its target's" : "stated"
            return "queue \(label) runs at \(runs.rawValue) (\(source)); ThreadRegistry.app declares \(row.policy.name)"
        }
        return nil
    }

    /// The QoS a queue runs at: the one it states, else its target's.
    static func effectiveQoS(_ qos: ThreadQoS, targetQoS: ThreadQoS?) -> ThreadQoS {
        qos == .unspecified ? targetQoS ?? .unspecified : qos
    }
}
