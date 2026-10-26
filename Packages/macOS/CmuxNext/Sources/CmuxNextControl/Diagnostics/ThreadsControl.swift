#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextCompat
internal import CmuxNextSettings
import Darwin

/// `debug.threads`: every thread of the app process with its requested QoS, effective priority, dispatch label
/// and CPU time, each compared with its row in the thread registry (plans/cmux-next/threading-model.md), plus
/// the process's task role (Debug and bench builds). The QoS audit (chrome-parity p02-threads RUN-3) reads it in
/// STRESS, with the window visible and hidden.
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
    private let mainThreadID: UInt64

    /// Makes the method; call it on the main actor, which names the main thread's row.
    ///
    /// - Parameter registry: The declared threads and queues (the app's by default).
    @MainActor
    public init(registry: ThreadRegistry = .app) {
        self.init(registry: registry, mainThreadID: LiveThread.currentThreadID())
    }

    init(registry: ThreadRegistry, mainThreadID: UInt64) {
        self.registry = registry
        self.mainThreadID = mainThreadID
    }

    /// The `debug.threads` control method.
    public var method: ControlMethod {
        .snapshot("debug.threads") { [self] _ in report() }
    }

    /// The report over this process's threads now.
    func report() -> JSONValue {
        Self.report(threads: LiveThread.all(), taskRole: LiveThread.taskRole(), registry: registry, mainThreadID: mainThreadID)
    }

    static func report(threads: [LiveThread], taskRole: String, registry: ThreadRegistry, mainThreadID: UInt64) -> JSONValue {
        var undeclared = 0
        var mismatched = 0
        var live: [ThreadDeclaration: Int] = [:]
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
            if let declaration {
                live[declaration, default: 0] += 1
                let matches = declaration.qos == thread.requestedQoS
                if !matches { mismatched += 1 }
                match = .bool(matches)
            } else {
                undeclared += 1
            }
            rows.append(.object([
                "tid": .number(Double(thread.id)),
                "name": .string(thread.name),
                "label": nullable(thread.label),
                "main": .bool(isMain),
                "requested_qos": nullable(thread.requestedQoS?.rawValue),
                "effective_pri": .number(Double(thread.effectivePriority)),
                "cpu_ms": .number(Double(thread.cpuNanos) / 1_000_000),
                "declared": nullable(declaration?.qos.rawValue),
                "declared_as": nullable(declaration?.name),
                "origin": nullable(declaration?.origin.rawValue),
                "match": match,
            ]))
        }
        return .object([
            "task_role": .string(taskRole),
            "thread_count": JSONValue(threads.count),
            "undeclared": JSONValue(undeclared),
            "mismatched": JSONValue(mismatched),
            "threads": .array(rows),
            "queues": .array(registry.rows.map { row in
                .object([
                    "name": .string(row.name),
                    "prefix": .bool(row.isPrefix),
                    "qos": .string(row.qos.rawValue),
                    "origin": .string(row.origin.rawValue),
                    "live_threads": JSONValue(live[row] ?? 0),
                ])
            }),
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
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
        let threads = UnsafeBufferPointer(start: list, count: Int(truncatingIfNeeded: count))
        defer {
            for thread in threads { mach_port_deallocate(mach_task_self_, thread) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(truncatingIfNeeded: threads.count * MemoryLayout<thread_act_t>.stride))
        }
        let labels = DispatchLabelReader()
        return threads.compactMap { read($0, labels: labels) }
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
        guard let identity = info(thread, THREAD_IDENTIFIER_INFO, thread_identifier_info_data_t()),
              let extended = info(thread, THREAD_EXTENDED_INFO, thread_extended_info_data_t()) else { return nil }
        let name = withUnsafeBytes(of: extended.pth_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return LiveThread(id: identity.thread_id, name: name, label: labels.label(slot: identity.dispatch_qaddr),
                          requestedQoS: requestedQoS(thread), effectivePriority: extended.pth_curpri,
                          cpuNanos: extended.pth_user_time &+ extended.pth_system_time)
    }

    private static func info<Info>(_ thread: thread_act_t, _ flavor: Int32, _ empty: Info) -> Info? {
        var info = empty
        var count = mach_msg_type_number_t(MemoryLayout<Info>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(truncatingIfNeeded: count)) { thread_info(thread, thread_flavor_t(flavor), $0, &count) }
        }
        return result == KERN_SUCCESS ? info : nil
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
