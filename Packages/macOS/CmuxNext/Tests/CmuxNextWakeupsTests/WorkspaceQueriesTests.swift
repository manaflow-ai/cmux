import AppKit
#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
#else
import CmuxNextCompat
#endif
import CmuxNextCompatAppKit
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
import UniformTypeIdentifiers

/// The app's Launch Services and icon answers (plans/cmux-next/chrome-parity/p02-threads.md, task 056): every question
/// is asked on BackgroundWork's system lane through the checked seams, never on the main thread, its answer comes back
/// on main and is kept in a bounded least-recently-used table, one question in flight serves every caller, and a kept
/// app answer older than the refresh age is served and asked again (Chrome's IconManager over IconLoader,
/// chrome/browser/icon_manager.cc).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct WorkspaceQueriesTests {
    static let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    static let xcode = URL(fileURLWithPath: "/Applications/Xcode.app")

    static func queries(_ system: RecordingWorkspace, work: BackgroundWork = BackgroundWork(label: "test.workspace-queries"),
                        capacity: Int = 256, iconCapacity: Int = 256, refreshAfter: Duration = .seconds(60),
                        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) -> WorkspaceQueries {
        WorkspaceQueries(work: work, mainWork: .still(), system: system, capacity: capacity, iconCapacity: iconCapacity,
                         refreshAfter: refreshAfter, now: now)
    }

    /// Runs main run loop passes until `done` or `seconds` (the answers come back as main run loop turns).
    static func spin(seconds: TimeInterval = 5, until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: seconds)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    @Test func aMissIsAskedOnTheSystemLaneAndAnsweredOnMain() {
        let system = RecordingWorkspace(apps: ["public.plain-text": [Self.textEdit, Self.xcode]])
        let queries = Self.queries(system)
        let question = WorkspaceQuery<[URL]>.applications(toOpen: .plainText)
        #expect(queries.cached(question) == nil)
        var answer: [URL]?
        var answeredOnMain = false
        queries.value(question, priority: .userBlocking) { apps in
            answer = apps
            answeredOnMain = Thread.isMainThread
        }
        #expect(answer == nil, "a miss never answers in the caller's turn")
        Self.spin { answer != nil }
        #expect(answer == [Self.textEdit, Self.xcode])
        #expect(answeredOnMain)
        #expect(system.asks.withLock { $0 } == 1)
        #expect(system.mainAsks.withLock { $0 } == 0, "Launch Services was asked on the main thread")
        #expect(system.laneLabels.withLock { $0 }.allSatisfy { $0.contains("system") }, "\(system.laneLabels.withLock { $0 })")
    }

    @Test func aKeptAnswerIsReadInTheCallersTurnWithNoSecondAsk() {
        let system = RecordingWorkspace(apps: ["public.plain-text": [Self.textEdit]])
        let queries = Self.queries(system)
        let question = WorkspaceQuery<[URL]>.applications(toOpen: .plainText)
        var first: [URL]?
        queries.value(question) { first = $0 }
        Self.spin { first != nil }
        var second: [URL]?
        queries.value(question) { second = $0 }
        #expect(second == [Self.textEdit], "a kept answer is given in the caller's turn")
        #expect(queries.cached(question) == [Self.textEdit])
        #expect(system.asks.withLock { $0 } == 1)
    }

    @Test func oneQuestionInFlightServesEveryCaller() {
        let system = RecordingWorkspace(apps: ["public.plain-text": [Self.textEdit]])
        let queries = Self.queries(system)
        let question = WorkspaceQuery<[URL]>.applications(toOpen: .plainText)
        var answers = 0
        for _ in 0..<5 { queries.value(question) { _ in answers += 1 } }
        queries.prefetch([question])
        Self.spin { answers == 5 }
        #expect(answers == 5)
        #expect(system.asks.withLock { $0 } == 1)
    }

    @Test func aKeptNilIsAnAnswerNotAMiss() {
        let system = RecordingWorkspace(apps: [:])
        let queries = Self.queries(system)
        let question = WorkspaceQuery<URL?>.application(withBundleIdentifier: "com.example.missing")
        var done = false
        queries.value(question) { _ in done = true }
        Self.spin { done }
        #expect(queries.cached(question) == .some(nil))
        #expect(system.asks.withLock { $0 } == 1)
    }

    @Test func theTableKeepsAtMostItsCapacityAndDropsTheLeastRecentlyRead() async throws {
        let system = RecordingWorkspace(apps: [:])
        let queries = Self.queries(system, capacity: 2)
        let a = WorkspaceQuery<URL?>.application(withBundleIdentifier: "a")
        let b = WorkspaceQuery<URL?>.application(withBundleIdentifier: "b")
        let c = WorkspaceQuery<URL?>.application(withBundleIdentifier: "c")
        _ = try await queries.value(a)
        _ = try await queries.value(b)
        _ = queries.cached(a)  // a read now: b is the least recently read
        _ = try await queries.value(c)
        #expect(queries.count == 2)
        #expect(queries.cached(a) != nil)
        #expect(queries.cached(b) == nil)
        #expect(queries.cached(c) != nil)
    }

    @Test func aStaleAppAnswerIsServedAndAskedAgain() async throws {
        let system = RecordingWorkspace(apps: ["public.plain-text": [Self.textEdit]])
        var now = ContinuousClock.now
        let queries = Self.queries(system, refreshAfter: .seconds(60), now: { now })
        let question = WorkspaceQuery<[URL]>.applications(toOpen: .plainText)
        _ = try await queries.value(question)
        system.apps.withLock { $0["public.plain-text"] = [Self.textEdit, Self.xcode] }
        now += .seconds(61)
        #expect(queries.cached(question) == [Self.textEdit], "the stale answer is served while it is asked again")
        Self.spin { system.asks.withLock { $0 } == 2 && queries.cached(question)?.count == 2 }
        #expect(queries.cached(question) == [Self.textEdit, Self.xcode])
    }

    @Test func anIconIsNeverAskedAgain() async throws {
        let system = RecordingWorkspace(apps: [:])
        var now = ContinuousClock.now
        let queries = Self.queries(system, refreshAfter: .seconds(1), now: { now })
        let question = WorkspaceQuery<NSImage>.fileIcon(atPath: Self.textEdit.path, side: 16)
        let icon = try await queries.value(question)
        #expect(icon.size == NSSize(width: 16, height: 16))
        now += .seconds(10)
        _ = queries.cached(question)
        Self.spin(seconds: 0.3) { false }
        #expect(system.asks.withLock { $0 } == 1)
    }

    /// A best-effort warm-up the startup fence holds does not hold a later user-blocking ask for the same answer: the
    /// ask raises the question in flight (before the fix the second ask joined it and waited for the fence to lift).
    @Test func aUserBlockingAskRaisesAWarmUpTheFenceHolds() {
        let system = RecordingWorkspace(apps: ["public.plain-text": [Self.textEdit]])
        let work = BackgroundWork(label: "test.workspace-queries.fence")
        let queries = Self.queries(system, work: work)
        let question = WorkspaceQuery<[URL]>.applications(toOpen: .plainText)
        work.beginBestEffortFence()
        defer { work.endBestEffortFence() }
        queries.prefetch([question], priority: .bestEffort)
        Self.spin(seconds: 0.3) { false }
        #expect(system.asks.withLock { $0 } == 0, "the fence holds the best-effort warm-up")
        var answer: [URL]?
        queries.value(question, priority: .userBlocking) { answer = $0 }
        Self.spin { answer != nil }
        #expect(answer == [Self.textEdit], "answered while the fence is still up")
        #expect(system.asks.withLock { $0 } == 1, "one question in flight, raised, not asked twice")
    }

    /// Icons are kept apart from the app answers: a folder of a few hundred apps' icons never drops a kept app list.
    @Test func manyIconsDoNotDropAKeptAppAnswer() async throws {
        let system = RecordingWorkspace(apps: ["public.plain-text": [Self.textEdit]])
        let queries = Self.queries(system, capacity: 4, iconCapacity: 8)
        let apps = WorkspaceQuery<[URL]>.applications(toOpen: .plainText)
        _ = try await queries.value(apps)
        for index in 0..<300 { _ = try await queries.value(WorkspaceQuery<NSImage>.fileIcon(atPath: "/apps/\(index).app", side: 16)) }
        #expect(queries.cached(apps) == [Self.textEdit])
        #expect(queries.count == 1)
        #expect(queries.iconCount == 8)
    }

    /// A memory release at the critical limit drops every kept icon and keeps no reference to it.
    @Test func aCriticalReleaseFreesTheKeptIcons() {
        let system = RecordingWorkspace(apps: [:])
        let queries = Self.queries(system)
        weak var weakIcon: NSImage?
        autoreleasepool {
            var landed = false
            queries.value(WorkspaceQuery<NSImage>.typeIcon(.plainText, side: 16)) { icon in
                weakIcon = icon
                landed = true
            }
            Self.spin { landed }
        }
        #expect(weakIcon != nil, "the table keeps the icon")
        #expect(queries.iconCount == 1)
        let progress = queries.releaseMemory(within: MemoryReleaseSlice(limit: .criticalThreshold, isExpired: { false }))
        #expect(progress == .done)
        #expect(queries.iconCount == 0)
        #expect(weakIcon == nil, "a released icon is freed")
    }

    /// An unkept question is shared by its callers but leaves nothing in the table: its caller owns the image.
    @Test func anUnkeptAnswerIsNotKept() {
        let system = RecordingWorkspace(apps: [:])
        let queries = Self.queries(system)
        let question = WorkspaceQuery<NSImage>.fileIcon(atPath: Self.textEdit.path).unkept
        var answers = 0
        queries.value(question) { _ in answers += 1 }
        queries.value(question) { _ in answers += 1 }
        Self.spin { answers == 2 }
        #expect(answers == 2)
        #expect(system.asks.withLock { $0 } == 1)
        #expect(queries.iconCount == 0)
        #expect(queries.cached(question) == nil)
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// The checked seams the system queries go through record nothing on the system lane: the lane may block.
    @Test func theSeamsOnTheSystemLaneRecordNoViolation() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let system = RecordingWorkspace(apps: ["public.plain-text": [Self.textEdit]], table: table)
        let queries = Self.queries(system)
        _ = try await queries.value(WorkspaceQuery<[URL]>.applications(toOpen: .plainText), priority: .userBlocking)
        _ = try await queries.value(WorkspaceQuery<NSImage>.typeIcon(.plainText, side: 16))
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty)
        #expect(system.asks.withLock { $0 } == 2)
    }

    /// The same seam called on the main thread is a violation: what the lane keeps off main.
    @Test func theSameSeamOnTheMainThreadRecordsOneSite() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let system = RecordingWorkspace(apps: [:], table: table)
        _ = system.applications(toOpen: UTType.plainText)
        await table.flush()
        #expect(BlockingDetector(table: table).sites.map(\.kind) == [.systemCall])
    }
    #endif
}

/// Launch Services from a table: counts the questions, the ones asked on the main thread and the queue labels they
/// ran on, and runs each through `blockingCall(.systemCall)` under the test's own table (when given), as the
/// checked seams do.
nonisolated final class RecordingWorkspace: WorkspaceQuerying {
    let apps: Mutex<[String: [URL]]>
    let asks = Mutex(0)
    let mainAsks = Mutex(0)
    let laneLabels = Mutex<[String]>([])
    #if DEBUG || CMUX_BLOCKING_CHECKS
    let table: BlockingViolationTable?
    #endif

    #if DEBUG || CMUX_BLOCKING_CHECKS
    init(apps: [String: [URL]], table: BlockingViolationTable? = nil) {
        self.apps = Mutex(apps)
        self.table = table
    }
    #else
    init(apps: [String: [URL]]) {
        self.apps = Mutex(apps)
    }
    #endif

    private func ask<T>(_ answer: () -> T) -> T {
        asks.withLock { $0 += 1 }
        if Thread.isMainThread { mainAsks.withLock { $0 += 1 } }
        laneLabels.withLock { $0.append(String(cString: __dispatch_queue_get_label(nil))) }
        #if DEBUG || CMUX_BLOCKING_CHECKS
        if let table { return BlockingViolationTable.$scoped.withValue(table) { blockingCall(.systemCall) { answer() } } }
        #endif
        return answer()
    }

    func application(withBundleIdentifier bundleIdentifier: String) -> URL? {
        ask { apps.withLock { $0[bundleIdentifier]?.first } }
    }

    func defaultApplication(toOpen url: URL) -> URL? { ask { nil } }

    func defaultApplication(toOpen type: UTType) -> URL? {
        ask { apps.withLock { $0[type.identifier]?.first } }
    }

    func applications(toOpen url: URL) -> [URL] { ask { [] } }

    func applications(toOpen type: UTType) -> [URL] {
        ask { apps.withLock { $0[type.identifier] ?? [] } }
    }

    func fileIcon(atPath path: String) -> NSImage { ask { NSImage(size: NSSize(width: 32, height: 32)) } }

    func typeIcon(_ type: UTType) -> NSImage { ask { NSImage(size: NSSize(width: 32, height: 32)) } }
}
