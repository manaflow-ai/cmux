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

    private static let registry = ThreadRegistry(rows: [
        ThreadDeclaration(utilityName, qos: .utility),
        ThreadDeclaration(queueLabel, qos: .utility),
        ThreadDeclaration("cmux-test.threads.prefix.", prefix: true, qos: .background, origin: .library),
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

    /// The comparison: the main thread by id, the name before the label, the longest prefix, mismatches counted.
    @Test func theReportComparesEachThreadWithItsRow() throws {
        let registry = ThreadRegistry(rows: [
            ThreadDeclaration(ThreadRegistry.mainThreadName, qos: .userInteractive),
            ThreadDeclaration("lane.", prefix: true, qos: .utility),
            ThreadDeclaration("lane.files.", prefix: true, qos: .userInitiated),
            ThreadDeclaration("named", qos: .default),
        ])
        let threads = [
            LiveThread(id: 1, name: "", label: nil, requestedQoS: .userInteractive, effectivePriority: 47, cpuNanos: 2_000_000),
            LiveThread(id: 2, name: "named", label: "lane.files.1", requestedQoS: .default, effectivePriority: 31, cpuNanos: 0),
            LiveThread(id: 3, name: "", label: "lane.files.2", requestedQoS: .utility, effectivePriority: 20, cpuNanos: 0),
            LiveThread(id: 4, name: "", label: nil, requestedQoS: nil, effectivePriority: 4, cpuNanos: 0),
        ]
        let report = ThreadsControl.report(threads: threads, taskRole: "foreground", registry: registry, mainThreadID: 1)
        let rows = try #require(report["threads"]?.arrayValue)
        #expect(rows.map { $0["declared_as"]?.stringValue } == [ThreadRegistry.mainThreadName, "named", "lane.files.", nil])
        #expect(rows.map { $0["match"] } == [.bool(true), .bool(true), .bool(false), .null])
        #expect(rows[0]["main"]?.boolValue == true)
        #expect(rows[0]["cpu_ms"] == .number(2))
        #expect(report["mismatched"]?.intValue == 1)
        #expect(report["undeclared"]?.intValue == 1)
        #expect(report["task_role"]?.stringValue == "foreground")
    }

    @Test func theRegistryPrefersAnExactRowThenTheLongestPrefix() {
        let registry = ThreadRegistry(rows: [
            ThreadDeclaration("a.", prefix: true, qos: .utility),
            ThreadDeclaration("a.b.", prefix: true, qos: .background),
            ThreadDeclaration("a.b.c", qos: .userInitiated),
        ])
        #expect(registry.declaration(for: "a.b.c")?.qos == .userInitiated)
        #expect(registry.declaration(for: "a.b.d")?.qos == .background)
        #expect(registry.declaration(for: "a.x")?.qos == .utility)
        #expect(registry.declaration(for: "b") == nil)
        #expect(registry.declaration(for: "") == nil)
    }

    /// Every queue `DispatchQueue.checked` would flag is a problem; a declared queue at its QoS is not.
    @Test func checkedQueuesAreComparedWithTheirDeclaration() {
        #expect(Self.registry.problem(label: Self.queueLabel, qos: .utility) == nil)
        #expect(Self.registry.problem(label: Self.queueLabel, qos: .userInitiated) != nil)
        #expect(Self.registry.problem(label: "cmux-test.threads.nobody", qos: .utility) != nil)
        #expect(ThreadRegistry.app.problem(label: "com.cmuxterm.app.next.blocking-drain", qos: .utility) == nil)
    }

    @Test func theAppRegistryHasNoDuplicateRows() {
        let names = ThreadRegistry.app.rows.map(\.name)
        #expect(Set(names).count == names.count)
    }

    /// Every app label threading-model.md registers has its row, a `<x>` interpolation as a prefix row, and the
    /// registry declares nothing the doc does not (the main thread aside).
    @Test func theAppRegistryIsThreadingModelsList() throws {
        let labels = try Self.documentedLabels()
        #expect(labels.count > 50)
        for label in labels {
            let row = ThreadRegistry.app.declaration(for: label.name)
            #expect(row?.name == label.name && row?.isPrefix == label.isPrefix, "\(label.name) has no matching row")
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

    /// The labels of threading-model.md's "Registered threads and queues" bullets, parenthesized notes left out;
    /// the Rust bullet (other processes) and the closing rule are not app rows.
    private static func documentedLabels() throws -> [(name: String, isPrefix: Bool)] {
        let doc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plans/cmux-next/threading-model.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        let start = try #require(text.range(of: "## Registered threads and queues"))
        let rest = text[start.upperBound...]
        let section = rest.range(of: "\n## ").map { rest[..<$0.lowerBound] } ?? rest
        var labels: [(name: String, isPrefix: Bool)] = []
        for bullet in section.components(separatedBy: "\n- ").dropFirst() {
            guard !bullet.hasPrefix("Trace and hang watch"), !bullet.hasPrefix("Every "),
                  let colon = bullet.firstIndex(of: ":") else { continue }
            var body = String(bullet[bullet.index(after: colon)...])
            while let close = body.firstIndex(of: ")"), let open = body[..<close].lastIndex(of: "(") {
                body.removeSubrange(open...close)
            }
            let spans = body.split(separator: "`", omittingEmptySubsequences: false)
            for (index, span) in spans.enumerated() where index % 2 == 1 {
                if let interpolation = span.firstIndex(of: "<") {
                    labels.append((name: String(span[..<interpolation]), isPrefix: true))
                } else {
                    labels.append((name: String(span), isPrefix: false))
                }
            }
        }
        return labels
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
