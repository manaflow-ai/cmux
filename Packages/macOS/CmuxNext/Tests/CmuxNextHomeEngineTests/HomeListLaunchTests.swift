import CmuxHomeCore
import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation
import Testing

/// The Home list's launch read on the main thread (p08-startup-076): a slow disk never holds the main thread.
/// The steps that need the last list run in their turn when the read has ended, else on its landing, in order.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HomeListLaunchTests {
    static let owner = "cmux-chief-home-list-launch-test"

    static func caches() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("home-list-launch-\(UUID().uuidString)", isDirectory: true)
    }

    static func read(caches: URL, work: BackgroundWork, _ body: @escaping @Sendable () -> HomeListLaunchRead.Value) -> HomeListLaunchRead {
        HomeListLaunchRead(owner: owner, caches: caches, conversations: HomeCache.standard(owner: owner, caches: caches),
                           sidebar: HomeSidebarLaunchCache.standard(owner: owner, caches: caches, files: work), on: work, body)
    }

    static func launch(_ read: HomeListLaunchRead?, owner: String = owner, caches: URL, work: BackgroundWork) -> HomeListLaunch {
        HomeListLaunch(read: read, owner: owner, caches: caches, work: work, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    /// Main run loop passes, where the landing's post arrives, until `done` or 5 s.
    static func spinMainRunLoop(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001)) }
    }

    @Test func aSlowReadRunsTheStepsOnItsLandingInOrderWithoutAWait() {
        let caches = Self.caches(), work = BackgroundWork()
        let gate = DispatchSemaphore(value: 0)
        let launch = Self.launch(Self.read(caches: caches, work: work) {
            gate.wait()
            return HomeListLaunchRead.Value(sidebar: HomeSidebarLaunchSnapshot(account: "acct_slow"))
        }, caches: caches, work: work)
        var ran: [String] = []
        let asked = ContinuousClock.now
        launch.whenRead { ran.append("seed \($0.sidebar?.account ?? "none")") }
        launch.whenRead { _ in ran.append("start") }
        #expect(ContinuousClock.now - asked < .milliseconds(50), "asking for the read waited for it")
        #expect(ran.isEmpty, "a step ran before the read ended")
        #expect(!launch.isLanded, "the list may draw before the read ended")
        gate.signal()
        Self.spinMainRunLoop { ran.count == 2 }
        #expect(ran == ["seed acct_slow", "start"])
        #expect(launch.isLanded, "the list still draws the theme background after the landing")
        launch.whenRead { _ in ran.append("late") }
        #expect(ran.last == "late", "a step asked after the landing runs in its own turn")
    }

    @Test func anEndedReadRunsTheStepInItsTurn() async {
        let caches = Self.caches(), work = BackgroundWork()
        let read = Self.read(caches: caches, work: work) { HomeListLaunchRead.Value() }
        _ = await read.finished()
        var ran = false
        Self.launch(read, caches: caches, work: work).whenRead { _ in ran = true }
        #expect(ran)
    }

    /// A Home of its own new caches folder (a test's AppServices) has nothing to read: it lands in the asking turn.
    @Test func aFolderWithNothingToReadLandsInItsTurn() {
        let caches = Self.caches(), work = BackgroundWork()
        let launch = Self.launch(HomeListLaunchRead.nothingToRead(owner: Self.owner, caches: caches, on: work), caches: caches, work: work)
        var seeded: HomeListLaunchRead.Value?
        launch.whenRead { seeded = $0 }
        #expect(seeded != nil && seeded?.conversations == nil && seeded?.sidebar == nil)
        #expect(launch.isLanded)
    }

    /// The app's read is taken only for the owner and folder it read; another Home starts its own.
    @Test func anotherOwnersReadIsNotTaken() {
        let caches = Self.caches(), work = BackgroundWork()
        let read = Self.read(caches: caches, work: work) { HomeListLaunchRead.Value() }
        #expect(Self.launch(read, owner: "cmux-chief-another", caches: caches, work: work).read.owner == "cmux-chief-another")
        #expect(Self.launch(read, caches: Self.caches(), work: work).read.caches != caches)
        #expect(Self.launch(read, caches: caches, work: work).read.owner == Self.owner)
    }
}
