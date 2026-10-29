import CmuxNextCompat
import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// The crash-key page: fixed slots written with relaxed stores, the outer value back after
/// a scoped key, the heap page moved into its file off main, and a crashed process's page decoding at the next
/// launch.
@Suite struct CrashKeysTests {
    private static let identity = CrashKeyPage.Identity(pid: 4242, role: .app, buildUUID: (1 ... 16).map { UInt8($0) },
                                                        processStartUnixMicros: 1_700_000_000_000_000, startUptimeNanos: 99)

    @Test func aKeyIsReadBackFromItsSlotAndTheHeaderNamesTheProcess() {
        let page = CrashKeyPage(identity: Self.identity)
        page.set(.daemonPID, 777)
        page.set(.daemonState, 2)
        page.set(.ghosttyCommit, 0xABCD_EF01_2345_6789)
        #expect(page.value(.daemonPID) == 777)
        let snapshot = page.snapshot()
        #expect(snapshot.words.count == CrashKeySlot.pageWordCount)
        #expect(snapshot.words[0] == CrashKeyPage.magic)
        #expect(snapshot[.daemonState] == 2)
        #expect(snapshot.identity == Self.identity)
        #expect(snapshot.tags["crash_key.daemon_pid"] == "777")
        #expect(snapshot.tags["crash_key.ghostty_commit"] == "abcdef0123456789")
        #expect(snapshot.tags["crash_key.action_index"] == nil, "a key at 0 is a tag")
    }

    /// The unclosed agent pane key holds when the pane was freed, not only its maker: a crash minutes later shows that
    /// the pane went long before, so it does not send the crash's owner to that pane (2026-10-28 review).
    @Test func theUnclosedAgentPaneKeySaysWhenThePaneWasFreed() {
        let page = CrashKeyPage(identity: Self.identity)
        page.set(.unclosedAgentPaneMaker, CrashKeySlot.unclosedAgentPane(maker: 2, uptimeNanos: 5_500_000_000))
        #expect(page.snapshot().tags["crash_key.unclosed_agent_pane_maker"] == "2@5.500s")
    }

    @Test func aScopedKeyPutsTheOuterValueBack() {
        let page = CrashKeyPage(identity: Self.identity)
        page.set(.inCEFPump, 0)
        var inner: UInt64 = 0, afterInner: UInt64 = 0
        do {
            let outer = ScopedCrashKey(page, .inCEFPump, 1)
            page.withKey(.actionIndex, 5) {
                page.withKey(.actionIndex, 6) { inner = page.value(.actionIndex) }
                afterInner = page.value(.actionIndex)
            }
            #expect(page.value(.inCEFPump) == 1)
            outer.end()
        }
        #expect(inner == 6)
        #expect(afterInner == 5)
        #expect(page.value(.actionIndex) == 0)
        #expect(page.value(.inCEFPump) == 0)
    }

    @Test func countsGoInPowerOfTwoBuckets() {
        #expect([0, 1, 2, 3, 4, 7, 8, 1000].map(CrashKeyPage.countBucket) == [0, 1, 2, 2, 4, 4, 8, 512])
        let page = CrashKeyPage(identity: Self.identity)
        page.setCount(.workspaceCount, 13)
        #expect(page.value(.workspaceCount) == 8)
    }

    @Test func aHangInProgressKeepsItsFramesAndClears() throws {
        let page = CrashKeyPage(identity: Self.identity)
        let frames = (0 ..< 70).map { CrashKeyPage.packedFrame(image: $0 % 3, offset: UInt64($0) * 16) }
        page.beginHang(startNanos: 5_000, frames: frames, imageUUIDWords: [1, 2, 3, 4])
        let hang = try #require(page.snapshot().hangInProgress)
        #expect(hang.startNanos == 5_000)
        #expect(hang.frames == Array(frames.prefix(CrashKeyPage.hangFrameCapacity)))
        #expect(hang.imageUUIDWords.prefix(4) == [1, 2, 3, 4])
        #expect(hang.frames[1] >> 48 == 1)
        page.endHang()
        #expect(page.snapshot().hangInProgress == nil)
    }

    @Test func adoptionMovesThePageIntoItsFileOnce() throws {
        let directory = try TraceRingCheck.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let page = CrashKeyPage(identity: Self.identity)
        page.set(.windowCount, 2)
        let path = try #require(page.adopt(directory: directory))
        #expect(path == directory + "/app-4242.crashkeys")
        #expect(page.isFileBacked)
        #expect(page.adopt(directory: directory) == nil, "a second adoption ran")
        page.set(.terminalCount, 4)
        let read = try #require(CrashKeyPage.read(atPath: path))
        #expect(read[.windowCount] == 2, "the heap value was not copied")
        #expect(read[.terminalCount] == 4, "a store after adoption did not reach the file")
        #expect(read.identity == Self.identity)
    }

    /// A writer that stores and scopes keys on one thread while another thread adopts the page loses no store and
    /// brings no ended scope back: once both end, the file holds every word the page holds.
    @Test func storesMadeDuringTheAdoptionAllReachTheFile() throws {
        let directory = try TraceRingCheck.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        for round in 0 ..< 100 {
            let pid = UInt32(20_000 + round)
            let page = CrashKeyPage(identity: .init(pid: pid, role: .app))
            DispatchQueue.concurrentPerform(iterations: 2) { lane in
                guard lane == 0 else {
                    _ = page.adopt(directory: directory)
                    return
                }
                // Runs before, through and after the adoption: until 256 stores went in after it ended.
                var stored: UInt64 = 0, afterAdoption = 0
                while afterAdoption < 256, stored < 2_000_000 {
                    stored += 1
                    page.set(.daemonPID, stored)
                    page.withKey(.actionIndex, stored) { page.set(.mainTaskOwner, stored) }
                    if page.isFileBacked { afterAdoption += 1 }
                }
            }
            let path = directory + "/" + CrashKeyPage.fileName(role: .app, pid: pid)
            let read = try #require(CrashKeyPage.read(atPath: path), "round \(round): no page in the file")
            #expect(read.words == page.snapshot().words, "round \(round): a store made during the adoption missed the file")
            #expect(read[.actionIndex] == 0, "round \(round): a scoped key came back after its scope ended")
            #expect(read[.daemonPID] == read[.mainTaskOwner], "round \(round): the last stores differ")
        }
    }

    @Test func aFailedAdoptionKeepsTheHeapPageAndCountsIt() {
        let page = CrashKeyPage(identity: Self.identity)
        page.set(.windowCount, 1)
        #expect(page.adopt(directory: "/dev/null/no") == nil)
        #expect(page.adoptFailures == 1)
        #expect(!page.isFileBacked)
        #expect(page.value(.windowCount) == 1)
    }

    @Test func aPageThatIsNotV1DoesNotDecode() {
        var bytes = [UInt8](repeating: 0, count: CrashKeyPage.byteCount)
        #expect(CrashKeyPage.decode(bytes) == nil)
        TraceRingCheck.put(&bytes, 0, CrashKeyPage.magic)
        TraceRingCheck.put(&bytes, 8, 2)
        #expect(CrashKeyPage.decode(bytes) == nil)
        #expect(CrashKeyPage.decode(Array(bytes.prefix(64))) == nil)
    }

    @Test func theRuntimeStoresIntoItsAttachedPage() {
        let runtime = TraceRuntime(role: .daemon)
        runtime.setCrashKey(.daemonPID, 1)
        #expect(runtime.crashKey(.daemonPID) == 0, "a key with no page went somewhere")
        let page = CrashKeyPage(identity: .init(role: .daemon))
        #expect(runtime.attachCrashKeys(page))
        #expect(!runtime.attachCrashKeys(CrashKeyPage(identity: .init(role: .daemon))), "a second page replaced the first")
        runtime.setCrashKey(.daemonPID, 31)
        #expect(page.value(.daemonPID) == 31)
        #expect(runtime.crashKey(.daemonPID) == 31)
    }

    @Test func theBlackBoxMakesAndAdoptsThePage() throws {
        let directory = try TraceRingCheck.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let runtime = TraceRuntime(role: .terminalHost)
        let blackBox = TraceBlackBox(role: .terminalHost, directory: directory, runtime: runtime,
                                     process: .init(pid: 5151, processStartUnixMicros: 12))
        #expect(runtime.crashKeys === blackBox.crashKeys)
        runtime.setCrashKey(.cefAPIVersion, 13_500)
        #expect(blackBox.adoptFile() != nil)
        let read = try #require(CrashKeyPage.read(atPath: directory + "/terminal-host-5151.crashkeys"))
        #expect(read[.cefAPIVersion] == 13_500)
        #expect(read.identity.processStartUnixMicros == 12)
    }

    /// A dead process's page goes once its black box is gone; a live process's page stays.
    @Test func cleanupDeletesThePagesOfDeadProcesses() throws {
        let directory = try TraceRingCheck.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        for name in ["app-100.crashkeys", "app-200.crashkeys"] {
            #expect(FileManager.default.createFile(atPath: directory + "/" + name, contents: Data(count: 8)))
        }
        var cleanup = TraceRingCleanup(directory: directory)
        cleanup.isAlive = { pid, _ in pid == 200 }
        let report = cleanup.run()
        #expect(report.deleted == ["app-100.crashkeys"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == ["app-200.crashkeys"])
    }

    /// A child that aborts right after storing its keys leaves a page that decodes with them.
    @Test func anAbortedChildLeavesADecodablePage() async throws {
        let directory = CrashKeysChild.directory(parent: getpid())
        defer { try? FileManager.default.removeItem(atPath: directory) }
        await #expect(processExitsWith: .signal(SIGABRT)) {
            CrashKeysChild.storeThenAbort()
        }
        let pages = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".crashkeys") }
        #expect(pages.count == 1)
        let read = try #require(CrashKeyPage.read(atPath: directory + "/" + (pages.first ?? "")), "the aborted child's page did not decode")
        #expect(read[.actionIndex] == CrashKeysChild.action)
        #expect(read[.daemonState] == 3)
        #expect(read.hangInProgress?.frames == [CrashKeyPage.packedFrame(image: 0, offset: 0x40)])
        #expect(read.identity.role == .app)
    }
}

/// The exit test's child: it stores keys on the heap, adopts the file, stores more inside a scoped key, and aborts.
enum CrashKeysChild {
    static let action: UInt64 = 0xC0FFEE

    static func directory(parent: pid_t) -> String {
        NSTemporaryDirectory() + "cmux-crash-keys-abort-\(parent)"
    }

    static func storeThenAbort() {
        let page = CrashKeyPage(identity: .init(role: .app))
        page.set(.daemonState, 3)
        guard page.adopt(directory: directory(parent: getppid())) != nil else { exit(3) }
        page.beginHang(startNanos: 1, frames: [CrashKeyPage.packedFrame(image: 0, offset: 0x40)], imageUUIDWords: [])
        page.withKey(.actionIndex, action) { abort() }
    }
}
