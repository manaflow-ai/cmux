#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextCompat
internal import CmuxNextSettings
import Darwin

/// `debug.threads`: every thread of the app process with its requested QoS, effective priority, dispatch label
/// and CPU time, each compared with its row in the thread registry (plans/cmux-next/threading-model.md), every
/// queue `DispatchQueue.checked` made, plus the process's task role (Debug and bench builds). The QoS audit
/// (chrome-parity p02-threads RUN-3) reads it in STRESS, with the window visible and hidden.
///
/// Requested QoS is the kernel's `THREAD_QOS_POLICY` tier, which excludes overrides (a waiter's boost, a
/// sync onto the queue), so `match` checks what the code asked for. Effective priority is
/// `THREAD_EXTENDED_INFO` `pth_curpri`, which includes them. Chrome reports the same per-thread type and
/// priority in chrome://tracing's thread metadata (base/threading/platform_thread_apple.mm).
///
/// It reads only Mach thread state, so it runs off the main thread (socket threading policy) and answers while
/// the main thread is busy.
public struct ThreadsControl: Sendable {
    private let registry: ThreadRegistry
    private let queueLog: CheckedQueueLog
    private let mainThreadID: UInt64

    /// Makes the method; call it on the main actor, which names the main thread's row.
    ///
    /// - Parameters:
    ///   - registry: The declared threads and queues (the app's by default).
    ///   - queueLog: The queues `DispatchQueue.checked` made (the app's by default).
    @MainActor
    public init(registry: ThreadRegistry = .app, queueLog: CheckedQueueLog = .app) {
        self.init(registry: registry, queueLog: queueLog, mainThreadID: LiveThread.currentThreadID())
    }

    init(registry: ThreadRegistry, queueLog: CheckedQueueLog = CheckedQueueLog(), mainThreadID: UInt64) {
        self.registry = registry
        self.queueLog = queueLog
        self.mainThreadID = mainThreadID
    }

    /// The `debug.threads` control method.
    public var method: ControlMethod {
        .snapshot("debug.threads") { [self] _ in report() }
    }

    /// The report over this process's threads and checked queues now.
    func report() -> JSONValue {
        Self.report(threads: LiveThread.all(), taskRole: LiveThread.taskRole(), registry: registry,
                    made: queueLog.records, droppedQueues: queueLog.droppedCount, mainThreadID: mainThreadID)
    }

    /// The report: each thread against its row, then each row and each undeclared checked queue with its live
    /// threads and the call sites that made it.
    ///
    /// A row's policy (``ThreadDeclaration/Policy``) gives the tiers its threads may ask for: one for a cmux row,
    /// focused, visible and hidden for a Ghostty surface's threads, any below user-interactive for a per-item
    /// queue, any for a thread whose library picks. `declared` is the policy's name (the QoS of a one-tier row),
    /// `declared_tiers` its tiers and `declared_hidden` the tier it asks for while what it works for is hidden.
    ///
    /// Counts: `mismatched` (a declared thread whose requested QoS was read and is not one of the row's tiers),
    /// `hidden_mismatched` (a declared thread whose row has a hidden tier and whose requested QoS is not it: the
    /// number the RUN-3 hidden run reads, where every Ghostty surface thread must be at utility),
    /// `unknown_qos` (a declared thread the kernel gave no QoS for, as when it exits mid-read: never a
    /// mismatch), `undeclared` (every thread no row declares, system and library threads included),
    /// `undeclared_cmux` (of those, the ones whose name or label has a cmux prefix: 0 when every cmux thread is
    /// registered), `undeclared_library` (of those, the ones whose name or label is in a linked library's name space,
    /// ``ThreadRegistry/libraryNamespaces``: 0 when every library thread has its row) and `queue_problems` (checked
    /// queues that do not match their row). The RUN-3 / MQ-15 target is 0 for `undeclared_cmux` plus
    /// `undeclared_library`; the rest of `undeclared` are the system's threads (idle GCD workers, AppKit, CoreAudio).
    static func report(threads: [LiveThread], taskRole: String, registry: ThreadRegistry, made: [CheckedQueueRecord] = [],
                       droppedQueues: Int = 0, mainThreadID: UInt64) -> JSONValue {
        var counts = Counts()
        var live: [ThreadDeclaration: Int] = [:]
        var liveUndeclaredLabels: [String: Int] = [:]
        var rows: [JSONValue] = []
        for thread in threads {
            let isMain = thread.id == mainThreadID
            let declaration: ThreadDeclaration?
            if isMain {
                declaration = registry.declaration(for: ThreadRegistry.mainThreadName)
            } else if let named = registry.declaration(for: thread.name) {
                declaration = named
            } else {
                declaration = thread.label.flatMap { registry.declaration(for: $0) }
            }
            var match: JSONValue = .null
            var undeclaredCmux = false
            var undeclaredLibrary: String?
            if let declaration {
                live[declaration, default: 0] += 1
                if let requested = thread.requestedQoS {
                    let matches = declaration.policy.allows(requested)
                    if !matches { counts.mismatched += 1 }
                    match = .bool(matches)
                    if let hidden = declaration.policy.hidden, hidden != requested { counts.hiddenMismatched += 1 }
                } else {
                    counts.unknownQoS += 1
                }
            } else {
                counts.undeclared += 1
                undeclaredCmux = registry.isOwn(thread.name) || thread.label.map(registry.isOwn) == true
                if undeclaredCmux {
                    counts.undeclaredCmux += 1
                } else {
                    undeclaredLibrary = registry.namespaceLibrary(of: thread.name) ?? thread.label.flatMap(registry.namespaceLibrary(of:))
                    if undeclaredLibrary != nil { counts.undeclaredLibrary += 1 }
                }
                if let label = thread.label { liveUndeclaredLabels[label, default: 0] += 1 }
            }
            let declaredTiers: JSONValue = declaration.map { tiers($0.policy) } ?? .null
            rows.append(.object([
                "tid": .number(Double(thread.id)),
                "name": .string(thread.name),
                "label": nullable(thread.label),
                "main": .bool(isMain),
                "requested_qos": nullable(thread.requestedQoS?.rawValue),
                "effective_pri": .number(Double(thread.effectivePriority)),
                "cpu_ms": .number(Double(thread.cpuNanos) / 1_000_000),
                "declared": nullable(declaration?.policy.name),
                "declared_tiers": declaredTiers,
                "declared_hidden": nullable(declaration?.policy.hidden?.rawValue),
                "declared_as": nullable(declaration?.name),
                "origin": nullable(declaration?.origin.rawValue),
                "library": nullable(declaration?.library),
                "undeclared_cmux": .bool(undeclaredCmux),
                "undeclared_library": nullable(undeclaredLibrary),
                "match": match,
            ]))
        }
        return .object([
            "task_role": .string(taskRole),
            "thread_count": JSONValue(threads.count),
            "undeclared": JSONValue(counts.undeclared),
            "undeclared_cmux": JSONValue(counts.undeclaredCmux),
            "undeclared_library": JSONValue(counts.undeclaredLibrary),
            "mismatched": JSONValue(counts.mismatched),
            "hidden_mismatched": JSONValue(counts.hiddenMismatched),
            "unknown_qos": JSONValue(counts.unknownQoS),
            "queue_problems": JSONValue(made.filter { $0.problem != nil }.count),
            "queues_not_recorded": JSONValue(droppedQueues),
            "threads": .array(rows),
            "queues": .array(queues(registry: registry, made: made, live: live, liveUndeclaredLabels: liveUndeclaredLabels)),
        ])
    }

    private struct Counts {
        var undeclared = 0
        var undeclaredCmux = 0
        var undeclaredLibrary = 0
        var mismatched = 0
        var hiddenMismatched = 0
        var unknownQoS = 0
    }

    /// Every row with its live threads and the checked queues made for it, then one entry per label of a
    /// checked queue no row declares, so an undeclared queue shows even while it is idle.
    private static func queues(registry: ThreadRegistry, made: [CheckedQueueRecord], live: [ThreadDeclaration: Int],
                               liveUndeclaredLabels: [String: Int]) -> [JSONValue] {
        var entries: [JSONValue] = registry.rows.map { row in
            .object([
                "name": .string(row.name),
                "declared": .bool(true),
                "match": .string(row.match.rawValue),
                "prefix": .bool(row.isPrefix),
                "qos": .string(row.policy.name),
                "tiers": tiers(row.policy),
                "origin": .string(row.origin.rawValue),
                "library": nullable(row.library),
                "live_threads": JSONValue(live[row] ?? 0),
                "made": .array(made.filter { $0.declaredAs == row.name }.map(site)),
            ])
        }
        let undeclared = Dictionary(grouping: made.filter { $0.declaredAs == nil }, by: \.label)
        var listed = Set<String>()
        for record in made where record.declaredAs == nil && listed.insert(record.label).inserted {
            let label = record.label
            let records = undeclared[label] ?? []
            entries.append(.object([
                "name": .string(label),
                "declared": .bool(false),
                "match": .null,
                "prefix": .bool(false),
                "qos": nullable(records.first?.qos.rawValue),
                "tiers": .null,
                "origin": .null,
                "library": .null,
                "live_threads": JSONValue(liveUndeclaredLabels[label] ?? 0),
                "made": .array(records.map(site)),
            ]))
        }
        return entries
    }

    private static func tiers(_ policy: ThreadDeclaration.Policy) -> JSONValue {
        .array(policy.tiers.map { .string($0.rawValue) })
    }

    private static func site(_ record: CheckedQueueRecord) -> JSONValue {
        .object([
            "label": .string(record.label),
            "qos": .string(record.qos.rawValue),
            "target": nullable(record.target),
            "site": .string(record.site),
            "count": JSONValue(record.count),
            "problem": nullable(record.problem),
        ])
    }

    private static func nullable(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }
}

/// One thread of this process as the kernel reports it.
struct LiveThread: Sendable, Equatable {
    var id: UInt64
    /// The pthread name; empty when unnamed.
    var name: String
    /// The label of the dispatch queue the thread is draining; nil when it drains none.
    var label: String?
    /// The QoS the thread asked for, overrides excluded; nil when the kernel did not say.
    var requestedQoS: ThreadQoS?
    var effectivePriority: Int32
    var cpuNanos: UInt64
}

extension LiveThread {
    /// This thread's system-wide id (`pthread_threadid_np`).
    static func currentThreadID() -> UInt64 {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        return id
    }

    /// Every thread of this process; a thread that exits while it is read is left out.
    static func all() -> [LiveThread] {
        let labels = DispatchLabelReader()
        return MachThreads().withTaskThreads { threads in threads.compactMap { read($0, labels: labels) } }
    }

    /// The process's Mach task role (`TASK_CATEGORY_POLICY`, mach/task_policy.h): `foreground` for the
    /// frontmost app, `background` once another app is active.
    static func taskRole() -> String {
        var role: integer_t = 0
        var count = mach_msg_type_number_t(1)
        var getDefault = boolean_t(0)
        guard task_policy_get(mach_task_self_, task_policy_flavor_t(TASK_CATEGORY_POLICY), &role, &count, &getDefault) == KERN_SUCCESS else {
            return "unknown"
        }
        // task_role_t, mach/task_policy.h: TASK_RENICED (-1) through TASK_DARWINBG_APPLICATION (8).
        return switch role {
        case -1: "reniced"
        case 0: "unspecified"
        case 1: "foreground"
        case 2: "background"
        case 3: "control"
        case 4: "graphics-server"
        case 5: "throttle"
        case 6: "nonui"
        case 7: "default"
        case 8: "darwinbg"
        default: "role-\(role)"
        }
    }

    private static func read(_ thread: thread_act_t, labels: DispatchLabelReader) -> LiveThread? {
        let mach = MachThreads()
        guard let identity = mach.info(thread, THREAD_IDENTIFIER_INFO, thread_identifier_info_data_t()),
              let extended = mach.info(thread, THREAD_EXTENDED_INFO, thread_extended_info_data_t()) else { return nil }
        return LiveThread(id: identity.thread_id, name: mach.name(of: extended), label: labels.label(slot: identity.dispatch_qaddr),
                          requestedQoS: requestedQoS(thread), effectivePriority: extended.pth_curpri,
                          cpuNanos: extended.pth_user_time &+ extended.pth_system_time)
    }

    /// `THREAD_QOS_POLICY` (9, xnu osfmk/mach/thread_policy.h; not in the public SDK headers): `qos_tier` is the
    /// requested tier, without the overrides the kernel applies on top.
    private static func requestedQoS(_ thread: thread_act_t) -> ThreadQoS? {
        var policy: (integer_t, integer_t) = (0, 0)
        var count = mach_msg_type_number_t(2)
        var getDefault = boolean_t(0)
        let result = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 2) { thread_policy_get(thread, thread_policy_flavor_t(9), $0, &count, &getDefault) }
        }
        return result == KERN_SUCCESS ? ThreadQoS(kernelTier: policy.0) : nil
    }
}

/// Reads the label of the queue a thread is draining the way lldb does: the thread's `dispatch_qaddr` slot holds
/// the queue, and libdispatch exports `dispatch_queue_offsets` for where a queue keeps its label. Every read goes
/// through `vm_read_overwrite`, so a queue freed mid-read gives nil, never a fault.
struct DispatchLabelReader {
    private let labelOffset: UInt?

    init() {
        // RTLD_DEFAULT; struct dispatch_queue_offsets_s { uint16_t dqo_version; uint16_t dqo_label; ... }.
        guard let offsets = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "dispatch_queue_offsets") else {
            labelOffset = nil
            return
        }
        labelOffset = UInt(truncatingIfNeeded: offsets.load(fromByteOffset: 2, as: UInt16.self))
    }

    func label(slot: UInt64) -> String? {
        guard let labelOffset, slot != 0,
              let queue = Self.word(at: UInt(truncatingIfNeeded: slot)), queue != 0,
              let text = Self.word(at: queue &+ labelOffset), text != 0 else { return nil }
        return Self.string(at: text)
    }

    private static func word(at address: UInt) -> UInt? {
        var value: UInt = 0
        var size: vm_size_t = 0
        let result = withUnsafeMutablePointer(to: &value) {
            vm_read_overwrite(mach_task_self_, vm_address_t(address), vm_size_t(MemoryLayout<UInt>.size),
                              vm_address_t(UInt(bitPattern: $0)), &size)
        }
        return result == KERN_SUCCESS && size == MemoryLayout<UInt>.size ? value : nil
    }

    /// The C string at `address`, read a page at a time so a short label at a page's end does not fault the
    /// read; at most `limit` bytes.
    private static func string(at address: UInt, limit: Int = 128) -> String? {
        let page = UInt(truncatingIfNeeded: getpagesize())
        var bytes: [UInt8] = []
        var next = address
        while bytes.count < limit {
            let chunk = Int(truncatingIfNeeded: min(UInt(truncatingIfNeeded: limit - bytes.count), page - next % page))
            var buffer = [UInt8](repeating: 0, count: chunk)
            var size: vm_size_t = 0
            let result = buffer.withUnsafeMutableBytes {
                vm_read_overwrite(mach_task_self_, vm_address_t(next), vm_size_t(truncatingIfNeeded: chunk), vm_address_t(UInt(bitPattern: $0.baseAddress)), &size)
            }
            guard result == KERN_SUCCESS else { return nil }
            if buffer.contains(0) { return String(decoding: bytes + buffer.prefix { $0 != 0 }, as: UTF8.self) }
            bytes += buffer
            next &+= UInt(truncatingIfNeeded: chunk)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
#endif
