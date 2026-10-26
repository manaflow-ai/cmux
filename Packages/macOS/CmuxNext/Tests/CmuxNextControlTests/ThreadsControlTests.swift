#if DEBUG
@testable import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `debug.threads` reads every live thread's requested QoS and compares it with the thread registry.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ThreadsControlTests {
    private static let utilityName = "cmux-test.threads.utility"
    private static let undeclaredName = "cmux-test.threads.undeclared"
    private static let queueLabel = "cmux-test.threads.queue"
    private static let operationQueueName = "cmux-test.threads.operations"
    private static let uncheckedLabel = "cmux-test.threads.nobody-declares"

    private static let registry = ThreadRegistry(rows: [
        ThreadDeclaration(utilityName, qos: .utility),
        ThreadDeclaration(queueLabel, qos: .utility),
        ThreadDeclaration(operationQueueName, match: .operationQueue, qos: .utility),
        ThreadDeclaration("cmux-test.threads.prefix.", match: .prefix, qos: .background, origin: .library),
    ])

    /// A named `.utility` Thread reads requested utility, declared utility, match true.
    @Test func aNamedUtilityThreadMatchesItsRow() async throws {
        let parked = await ParkedThread.start(name: Self.utilityName, qos: .utility)
        defer { parked.release() }

        let rows = try Self.rows(named: Self.utilityName)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["requested_qos"]?.stringValue == "utility")
        #expect(row["declared"]?.stringValue == "utility")
        #expect(row["origin"]?.stringValue == "cmux")
        #expect(row["match"]?.boolValue == true)
        #expect(row["effective_pri"]?.intValue.map { $0 > 0 } == true)
    }

    /// A thread no row declares reads declared null and match null, and counts as undeclared.
    @Test func anUndeclaredThreadHasNullDeclaration() async throws {
        let parked = await ParkedThread.start(name: Self.undeclaredName, qos: .userInitiated)
        defer { parked.release() }

        let report = ThreadsControl(registry: Self.registry, mainThreadID: 0).report()
        let row = try #require(try Self.rows(named: Self.undeclaredName, in: report).first)
        #expect(row["requested_qos"]?.stringValue == "user-initiated")
        #expect(row["declared"] == .null)
        #expect(row["match"] == .null)
        #expect(report["undeclared"]?.intValue.map { $0 >= 1 } == true)
    }

    /// A thread draining a queue reports the queue's label (read through `dispatch_qaddr`) and matches its row.
    @Test func aQueueThreadReportsItsLabel() async throws {
        let queue = DispatchQueue(label: Self.queueLabel, qos: .utility)
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            queue.async {
                started.resume()
                release.blockingWait()
            }
        }
        defer { release.signal() }

        let threads = LiveThread.all().filter { $0.label == Self.queueLabel }
        #expect(threads.count == 1)
        let report = ThreadsControl.report(threads: threads, taskRole: "foreground", registry: Self.registry, mainThreadID: 0)
        let row = try #require(report["threads"]?.arrayValue?.first)
        #expect(row["declared_as"]?.stringValue == Self.queueLabel)
        #expect(row["match"]?.boolValue == true)
        let queues = try #require(report["queues"]?.arrayValue)
        #expect(queues.first { $0["name"]?.stringValue == Self.queueLabel }?["live_threads"]?.intValue == 1)
    }

    /// A thread running an operation of a named `.utility` OperationQueue (a URLSession delegate queue's shape)
    /// matches the queue's `operation-queue` row through the label Foundation gives the operation's queue.
    @Test func anOperationQueueThreadMatchesItsRow() async throws {
        let queue = OperationQueue()
        queue.name = Self.operationQueueName
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        let release = DispatchSemaphore(value: 0)
        let threadID = await withCheckedContinuation { (started: CheckedContinuation<UInt64, Never>) in
            queue.addOperation {
                started.resume(returning: LiveThread.currentThreadID())
                release.blockingWait()
            }
        }
        defer { release.signal() }

        let thread = try #require(LiveThread.all().first { $0.id == threadID })
        let report = ThreadsControl.report(threads: [thread], taskRole: "foreground", registry: Self.registry, mainThreadID: 0)
        let row = try #require(report["threads"]?.arrayValue?.first)
        #expect(row["declared_as"]?.stringValue == Self.operationQueueName, "the operation's queue label: \(thread.label ?? "none")")
        #expect(row["requested_qos"]?.stringValue == "utility")
        #expect(row["match"]?.boolValue == true)
    }

    /// The comparison: the main thread by id, the name before the label, the longest prefix, mismatches counted;
    /// an unread QoS is unknown, not a mismatch; an unmatched cmux name is counted apart from system threads.
    @Test func theReportComparesEachThreadWithItsRow() throws {
        let registry = ThreadRegistry(rows: [
            ThreadDeclaration(ThreadRegistry.mainThreadName, qos: .userInteractive),
            ThreadDeclaration("lane.", match: .prefix, qos: .utility),
            ThreadDeclaration("lane.files.", match: .prefix, qos: .userInitiated),
            ThreadDeclaration("named", qos: .default),
        ], ownPrefixes: ["cmux"])
        let threads = [
            LiveThread(id: 1, name: "", label: nil, requestedQoS: .userInteractive, effectivePriority: 47, cpuNanos: 2_000_000),
            LiveThread(id: 2, name: "named", label: "lane.files.1", requestedQoS: .default, effectivePriority: 31, cpuNanos: 0),
            LiveThread(id: 3, name: "", label: "lane.files.2", requestedQoS: .utility, effectivePriority: 20, cpuNanos: 0),
            LiveThread(id: 4, name: "", label: nil, requestedQoS: nil, effectivePriority: 4, cpuNanos: 0),
            LiveThread(id: 5, name: "", label: "lane.3", requestedQoS: nil, effectivePriority: 4, cpuNanos: 0),
            LiveThread(id: 6, name: "cmux stray", label: nil, requestedQoS: .utility, effectivePriority: 20, cpuNanos: 0),
            LiveThread(id: 7, name: "", label: "com.apple.root.utility-qos", requestedQoS: .utility, effectivePriority: 20, cpuNanos: 0),
        ]
        let report = ThreadsControl.report(threads: threads, taskRole: "foreground", registry: registry, mainThreadID: 1)
        let rows = try #require(report["threads"]?.arrayValue)
        #expect(rows.map { $0["declared_as"]?.stringValue } == [ThreadRegistry.mainThreadName, "named", "lane.files.", nil, "lane.", nil, nil])
        #expect(rows.map { $0["match"] } == [.bool(true), .bool(true), .bool(false), .null, .null, .null, .null])
        #expect(rows.map { $0["undeclared_cmux"]?.boolValue } == [false, false, false, false, false, true, false])
        #expect(rows[0]["main"]?.boolValue == true)
        #expect(rows[0]["cpu_ms"] == .number(2))
        #expect(report["mismatched"]?.intValue == 1)
        #expect(report["unknown_qos"]?.intValue == 1)
        #expect(report["undeclared"]?.intValue == 3)
        #expect(report["undeclared_cmux"]?.intValue == 1)
        #expect(report["task_role"]?.stringValue == "foreground")
    }

    @Test func theRegistryPrefersAnExactRowThenTheLongestPrefix() {
        let registry = ThreadRegistry(rows: [
            ThreadDeclaration("a.", match: .prefix, qos: .utility),
            ThreadDeclaration("a.b.", match: .prefix, qos: .background),
            ThreadDeclaration("a.b.c", qos: .userInitiated),
            ThreadDeclaration("ops", match: .operationQueue, qos: .default),
        ])
        #expect(registry.declaration(for: "a.b.c")?.qos == .userInitiated)
        #expect(registry.declaration(for: "a.b.d")?.qos == .background)
        #expect(registry.declaration(for: "a.x")?.qos == .utility)
        #expect(registry.declaration(for: "b") == nil)
        #expect(registry.declaration(for: "") == nil)
        #expect(registry.declaration(for: "ops")?.qos == .default)
        #expect(registry.declaration(for: "ops :: NSOperation 0x600000c0c000 (QOS: DEFAULT)")?.qos == .default)
        #expect(registry.declaration(for: "ops2") == nil)
    }

    /// Every queue `DispatchQueue.checked` would flag is a problem; a declared queue at its QoS, or with no QoS
    /// and a target at the declared one, is not.
    @Test func checkedQueuesAreComparedWithTheirDeclaration() {
        #expect(Self.registry.problem(label: Self.queueLabel, qos: .utility) == nil)
        #expect(Self.registry.problem(label: Self.queueLabel, qos: .userInitiated) != nil)
        #expect(Self.registry.problem(label: "cmux-test.threads.nobody", qos: .utility) != nil)
        #expect(Self.registry.problem(label: Self.queueLabel, qos: .unspecified, targetQoS: .utility) == nil)
        #expect(Self.registry.problem(label: Self.queueLabel, qos: .unspecified, targetQoS: .userInitiated) != nil)
        #expect(Self.registry.problem(label: Self.queueLabel, qos: .unspecified) != nil)
        #expect(Self.registry.problem(label: Self.queueLabel, qos: .unspecified, targetQoS: .unspecified) != nil)
        #expect(ThreadRegistry.app.problem(label: "com.cmuxterm.app.next.blocking-drain", qos: .utility) == nil)
    }

    /// A queue that states only a target runs at, and is recorded at, the target's QoS.
    @Test func aTargetOnlyQueueTakesItsTargetsQoS() {
        let log = CheckedQueueLog()
        let target = DispatchQueue(label: "cmux-test.threads.target", qos: .utility)
        let record = log.record(label: Self.queueLabel, qos: .unspecified, target: target, site: "here:1", registry: Self.registry)
        #expect(record.problem == nil)
        #expect(record.qos == .utility)
        #expect(record.target == "cmux-test.threads.target")
        let bare = log.record(label: Self.queueLabel, qos: .unspecified, target: nil, site: "here:2", registry: Self.registry)
        #expect(bare.problem != nil)
        #expect(log.records.count == 2)
    }

    /// `DispatchQueue.checked` records each queue, declared or not, and `debug.threads` lists both under `queues`.
    @Test func checkedQueuesAreListedInTheReport() throws {
        let declared = DispatchQueue.checked(label: "com.cmuxterm.app.next.blocking-drain", qos: .utility)
        let undeclared = DispatchQueue.checked(label: Self.uncheckedLabel, qos: .utility)
        #expect(declared.label != undeclared.label)

        let mine = CheckedQueueLog.app.records.filter { $0.site.hasPrefix("CmuxNextControlTests/ThreadsControlTests.swift:") }
        let declaredRecord = try #require(mine.first { $0.label == "com.cmuxterm.app.next.blocking-drain" })
        #expect(declaredRecord.declaredAs == "com.cmuxterm.app.next.blocking-drain")
        #expect(declaredRecord.problem == nil)
        let undeclaredRecord = try #require(mine.first { $0.label == Self.uncheckedLabel })
        #expect(undeclaredRecord.declaredAs == nil)
        #expect(undeclaredRecord.problem != nil)

        let report = ThreadsControl(registry: .app, queueLog: .app, mainThreadID: 0).report()
        let queues = try #require(report["queues"]?.arrayValue)
        let drain = try #require(queues.first { $0["name"]?.stringValue == "com.cmuxterm.app.next.blocking-drain" })
        #expect(drain["declared"]?.boolValue == true)
        #expect(drain["made"]?.arrayValue?.contains { $0["site"]?.stringValue == declaredRecord.site } == true)
        let stray = try #require(queues.first { $0["name"]?.stringValue == Self.uncheckedLabel })
        #expect(stray["declared"]?.boolValue == false)
        #expect(stray["made"]?.arrayValue?.first?["problem"]?.stringValue == undeclaredRecord.problem)
        #expect(report["queue_problems"]?.intValue.map { $0 >= 1 } == true)
    }

    @Test func theAppRegistryHasNoDuplicateRows() {
        let names = ThreadRegistry.app.rows.map(\.name)
        #expect(Set(names).count == names.count)
    }

    /// Every app label threading-model.md registers has its row with the doc's match kind and QoS (the QoS the
    /// parentheses after the label start with), and the registry declares nothing the doc does not (the main
    /// thread aside).
    @Test func theAppRegistryIsThreadingModelsList() throws {
        let labels = try Self.documentedLabels()
        #expect(labels.count > 50)
        for label in labels {
            let row = ThreadRegistry.app.rows.first { $0.name == label.name }
            #expect(row?.match == label.match, "\(label.name): the doc's match kind is \(label.match.rawValue)")
            #expect(label.qos != nil, "\(label.name): the doc gives no QoS in the parentheses after it")
            #expect(row?.qos == label.qos, "\(label.name): the doc declares \(label.qos?.rawValue ?? "none"), the registry \(row?.qos.rawValue ?? "no row")")
        }
        let documented = Set(labels.map { $0.name })
        let undocumented = ThreadRegistry.app.rows.map(\.name).filter { $0 != ThreadRegistry.mainThreadName && !documented.contains($0) }
        #expect(undocumented.isEmpty, "rows not in threading-model.md: \(undocumented)")
    }

    @Test func kernelTiersMapToQoS() {
        #expect((0...6).compactMap { ThreadQoS(kernelTier: Int32($0)) }
                == [.unspecified, .maintenance, .background, .utility, .default, .userInitiated, .userInteractive])
        #expect(ThreadQoS(kernelTier: 7) == nil)
    }

    @Test func theTaskRoleIsRead() {
        #expect(LiveThread.taskRole() != "unknown")
    }

    private struct DocumentedLabel {
        var name: String
        var match: ThreadDeclaration.Match
        var qos: ThreadQoS?
    }

    /// The labels of threading-model.md's "Registered threads and queues" bullets, each with the parentheses
    /// right after it: they start with `OperationQueue, ` for an OperationQueue name, then the QoS. The Rust
    /// bullet (other processes) and the closing rule are not app rows; a backticked word inside parentheses is
    /// not a label.
    private static func documentedLabels() throws -> [DocumentedLabel] {
        let doc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plans/cmux-next/threading-model.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        let start = try #require(text.range(of: "## Registered threads and queues"))
        let rest = text[start.upperBound...]
        let section = rest.range(of: "\n## ").map { rest[..<$0.lowerBound] } ?? rest
        var labels: [DocumentedLabel] = []
        for bullet in section.components(separatedBy: "\n- ").dropFirst() {
            guard !bullet.hasPrefix("Trace and hang watch"), !bullet.hasPrefix("Every "),
                  let colon = bullet.firstIndex(of: ":") else { continue }
            var body = bullet[bullet.index(after: colon)...]
            while let open = body.firstIndex(of: "`") {
                let spanStart = body.index(after: open)
                guard let close = body[spanStart...].firstIndex(of: "`") else { break }
                let span = body[spanStart..<close]
                body = body[body.index(after: close)...]
                let note = parenthesized(&body)
                var parts = note.split { ",;:".contains($0) }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                let isOperationQueue = parts.first == "OperationQueue"
                if isOperationQueue { parts.removeFirst() }
                let qos = parts.first.flatMap(ThreadQoS.init(rawValue:))
                if let interpolation = span.firstIndex(of: "<") {
                    labels.append(DocumentedLabel(name: String(span[..<interpolation]), match: .prefix, qos: qos))
                } else {
                    labels.append(DocumentedLabel(name: String(span), match: isOperationQueue ? .operationQueue : .exact, qos: qos))
                }
            }
        }
        return labels
    }

    /// The text inside the parentheses that open right after `text`'s spaces, removed from `text`; empty when none
    /// open there.
    private static func parenthesized(_ text: inout Substring) -> String {
        let afterSpaces = text.drop { $0 == " " }
        guard afterSpaces.first == "(" else { return "" }
        var depth = 0
        for index in afterSpaces.indices {
            switch afterSpaces[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    text = afterSpaces[afterSpaces.index(after: index)...]
                    return String(afterSpaces[afterSpaces.index(after: afterSpaces.startIndex)..<index])
                }
            default: break
            }
        }
        text = afterSpaces[afterSpaces.endIndex...]
        return String(afterSpaces.dropFirst())
    }

    private static func rows(named name: String, in report: JSONValue? = nil) throws -> [JSONValue] {
        let report = report ?? ThreadsControl(registry: registry, mainThreadID: 0).report()
        return try #require(report["threads"]?.arrayValue).filter { $0["name"]?.stringValue == name }
    }
}

/// A named Thread at a QoS that stays alive until ``release()``.
private final class ParkedThread: Sendable {
    private let gate = DispatchSemaphore(value: 0)

    static func start(name: String, qos: QualityOfService) async -> ParkedThread {
        let parked = ParkedThread()
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            let thread = Thread { [gate = parked.gate] in
                started.resume()
                gate.blockingWait()
            }
            thread.name = name
            thread.qualityOfService = qos
            thread.start()
        }
        return parked
    }

    func release() {
        gate.signal()
    }
}
#endif
