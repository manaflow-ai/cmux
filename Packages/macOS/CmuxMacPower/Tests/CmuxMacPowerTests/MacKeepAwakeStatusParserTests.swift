import Testing

@testable import CmuxMacPower

@Suite("MacKeepAwakeStatusParser")
struct MacKeepAwakeStatusParserTests {
    /// A fully idle Mac: a system-wide block with all-zero counts and no owning
    /// processes => nothing is keeping it awake.
    @Test func idleOutputReportsNotKeptAwake() {
        let output = """
        2024-06-26 10:00:00 -0700
        Assertion status system-wide:
           BackgroundTask                 0
           ApplePushServiceTask           0
           UserIsActive                   0
           PreventUserIdleDisplaySleep    0
           PreventSystemSleep             0
           ExternalMedia                  0
           PreventUserIdleSystemSleep     0
           NetworkClientActive            0
        Listed by owning process:
        No assertions.
        """
        let status = MacKeepAwakeStatusParser.parse(output)
        #expect(status.keptAwake == false)
        #expect(status.preventsSystemSleep == false)
        #expect(status.preventsDisplaySleep == false)
        #expect(status.cmuxKeepingAwake == false)
        #expect(status.caffeinateRunning == false)
        #expect(status.holders.isEmpty)
    }

    /// The canonical case the issue cares about: a `caffeinate` process holding a
    /// system-sleep assertion. Status reports kept-awake + caffeinate, and the
    /// holder is parsed with pid/name/type/detail.
    @Test func caffeinateHoldingSystemSleepIsDetected() throws {
        let output = """
        Assertion status system-wide:
           PreventUserIdleSystemSleep     1
        Listed by owning process:
           pid 42(caffeinate): [0x00000d65000204a0] 00:13:25 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
        """
        let status = MacKeepAwakeStatusParser.parse(output)
        #expect(status.keptAwake)
        #expect(status.preventsSystemSleep)
        #expect(status.preventsDisplaySleep == false)
        #expect(status.caffeinateRunning)
        #expect(status.cmuxKeepingAwake == false)
        #expect(status.holders.count == 1)
        let holder = try #require(status.holders.first)
        #expect(holder.pid == 42)
        #expect(holder.processName == "caffeinate")
        #expect(holder.assertionTypes == ["PreventUserIdleSystemSleep"])
        #expect(holder.detail == "caffeinate command-line tool")
    }

    /// cmux itself holding an assertion sets `cmuxKeepingAwake` (the "kept awake
    /// by cmux" the issue asks to surface). Matches the tagged DEV process name.
    @Test func cmuxProcessSetsCmuxKeepingAwake() {
        let output = """
        Listed by owning process:
           pid 88(cmux DEV my-tag): [0x000a] PreventUserIdleSystemSleep named: "cmux keep awake"
        """
        let status = MacKeepAwakeStatusParser.parse(output)
        #expect(status.cmuxKeepingAwake)
        #expect(status.keptAwake)
        #expect(status.holders.first?.processName == "cmux DEV my-tag")
    }

    /// A display-only assertion keeps the Mac awake but is reported as display,
    /// not system, sleep prevention.
    @Test func displayOnlyAssertionIsDisplayNotSystem() {
        let output = """
        Listed by owning process:
           pid 367(Google Chrome): [0x000b] 00:00:01 PreventUserIdleDisplaySleep named: "playing audio"
        """
        let status = MacKeepAwakeStatusParser.parse(output)
        #expect(status.keptAwake)
        #expect(status.preventsDisplaySleep)
        #expect(status.preventsSystemSleep == false)
        #expect(status.holders.first?.processName == "Google Chrome")
    }

    /// Multiple assertion lines for the same pid merge into one holder with the
    /// union of its assertion types (deduplicated, order preserved).
    @Test func multipleAssertionsForSamePidMerge() throws {
        let output = """
        Listed by owning process:
           pid 42(caffeinate): [0x000a] PreventUserIdleSystemSleep named: "caffeinate command-line tool"
           pid 42(caffeinate): [0x000b] PreventUserIdleDisplaySleep named: "caffeinate command-line tool"
           pid 42(caffeinate): [0x000c] PreventUserIdleSystemSleep named: "caffeinate command-line tool"
        """
        let status = MacKeepAwakeStatusParser.parse(output)
        #expect(status.holders.count == 1)
        #expect(status.preventsSystemSleep)
        #expect(status.preventsDisplaySleep)
        let holder = try #require(status.holders.first)
        #expect(holder.assertionTypes == ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep"])
    }

    /// The kernel-assertions section (which follows the owning-process list and
    /// is not indented the same way) must not leak in as a holder.
    @Test func ignoresKernelAssertionsSection() {
        let output = """
        Listed by owning process:
           pid 42(caffeinate): [0x000a] PreventUserIdleSystemSleep named: "caffeinate command-line tool"
        Kernel Assertions: 0x4=USB
           id=500 level=255 0x4=USB mod=06/26/24 description=com.apple.usb.externaldevice
        """
        let status = MacKeepAwakeStatusParser.parse(output)
        #expect(status.holders.count == 1)
        #expect(status.holders.first?.processName == "caffeinate")
    }

    /// Two different processes each keeping the Mac awake are both surfaced; the
    /// aggregate booleans reflect the union.
    @Test func multipleProcessesAllSurface() {
        let output = """
        Listed by owning process:
           pid 42(caffeinate): [0x000a] PreventUserIdleSystemSleep named: "caffeinate command-line tool"
           pid 99(Amphetamine): [0x000b] PreventUserIdleSystemSleep named: "User session"
        """
        let status = MacKeepAwakeStatusParser.parse(output)
        #expect(status.holders.count == 2)
        #expect(status.caffeinateRunning)
        #expect(status.cmuxKeepingAwake == false)
        #expect(Set(status.holders.map(\.pid)) == [42, 99])
    }

    /// A garbage line that starts with "pid" but has no `(name)` head is ignored
    /// rather than producing a bogus holder.
    @Test func malformedProcessLineIgnored() {
        let output = """
        Listed by owning process:
           pid not-a-real-line
           pid 42(caffeinate): [0x000a] PreventUserIdleSystemSleep named: "caffeinate command-line tool"
        """
        let status = MacKeepAwakeStatusParser.parse(output)
        #expect(status.holders.count == 1)
        #expect(status.holders.first?.pid == 42)
    }

    /// Empty pmset output (e.g. a failed run already mapped to "") is idle, not a
    /// crash.
    @Test func emptyOutputIsIdle() {
        #expect(MacKeepAwakeStatusParser.parse("") == .idle)
    }

    /// An owning-process line with no recognized assertion type contributes no
    /// holder (only sleep-relevant assertions count).
    @Test func processWithNoKnownAssertionTypeDropped() {
        let output = """
        Listed by owning process:
           pid 200(somed): [0x000a] SomeUnknownAssertion named: "irrelevant"
        """
        let status = MacKeepAwakeStatusParser.parse(output)
        #expect(status.holders.isEmpty)
        #expect(status.keptAwake == false)
    }
}
