@testable import CmuxNextApp
import CmuxNextAgentActivity
import CmuxNextTerminal
import Darwin
import Foundation
import Testing

/// cx-9dh7: the app never writes its own process environment after launch.
/// libghostty keeps a slice of `environ` from `ghostty_init`; an `unsetenv`
/// at launch (CMUX_NEXT_CUA_SOCKET inherited) shifted the entries under it
/// and `ghostty_config_finalize` read a NULL entry (SIGSEGV), and a `setenv`
/// of a new key can move `environ` and leave it reading freed memory.
/// Each test compares `environ` (the array address, every entry's address
/// and bytes) before and after, with the real (non-injected) daemon.
@MainActor
@Suite(.serialized) struct ComputerUseEnvironmentSafetyTests {
    struct EnvironSnapshot: Equatable {
        var array: UInt
        var entries: [UInt]
        var bytes: [String]

        static func take() -> EnvironSnapshot {
            let base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = environ
            var entries: [UInt] = []
            var bytes: [String] = []
            var index = 0
            while let base, let entry = base[index] {
                entries.append(UInt(bitPattern: entry))
                bytes.append(String(cString: entry))
                index += 1
            }
            return EnvironSnapshot(array: UInt(bitPattern: base), entries: entries, bytes: bytes)
        }
    }

    static func daemon(_ launcher: ComputerUseHelperDaemonTests.FakeLauncher) -> (ComputerUseHelperDaemon, String) {
        let id = UUID().uuidString.prefix(8)
        let socket = "/tmp/cu-env-\(id)/s/cua.sock"
        let daemon = ComputerUseHelperDaemon(identity: CuaHelperIdentity { $0 == ComputerUseHelperDaemonTests.nightly },
                                             candidates: { [ComputerUseHelperDaemonTests.nightly] }, launcher: launcher,
                                             socketPath: socket,
                                             stateDirectory: FileManager.default.temporaryDirectory.appending(path: "cu-env-st-\(id)"))
        return (daemon, socket)
    }

    /// Launch: Computer Use is off, so `follow` applies `false` first. With
    /// CMUX_NEXT_CUA_SOCKET in the launch environment (the coordinator's
    /// nxdog69 preflight; run this suite with it set to reproduce), the
    /// environment stays exactly as launched, the variable included.
    @Test func launchWithComputerUseOffLeavesTheEnvironmentUnchanged() async {
        let launched = ProcessInfo.processInfo.environment["CMUX_NEXT_CUA_SOCKET"]
        let before = EnvironSnapshot.take()
        let (daemon, _) = Self.daemon(ComputerUseHelperDaemonTests.FakeLauncher())
        await daemon.apply(enabled: false)
        daemon.applicationWillTerminate()
        #expect(EnvironSnapshot.take() == before, "the launch path wrote the process environment")
        #expect(getenv("CMUX_NEXT_CUA_SOCKET").map { String(cString: $0) } == launched)
    }

    /// Computer Use on, off, on, then quit: no setenv, unsetenv or putenv.
    @Test func togglingComputerUseNeverWritesTheEnvironment() async {
        let launcher = ComputerUseHelperDaemonTests.FakeLauncher()
        let (daemon, socket) = Self.daemon(launcher)
        defer { try? FileManager.default.removeItem(atPath: ((socket as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent) }
        let before = EnvironSnapshot.take()
        await daemon.apply(enabled: true)
        #expect(launcher.launches.count == 1, "the helper did not start, so the toggle proves nothing")
        #expect(EnvironSnapshot.take() == before, "turning Computer Use on wrote the process environment")
        await daemon.apply(enabled: false)
        #expect(EnvironSnapshot.take() == before, "turning Computer Use off wrote the process environment")
        await daemon.apply(enabled: true)
        daemon.applicationWillTerminate()
        #expect(EnvironSnapshot.take() == before, "turning Computer Use on again or quitting wrote the process environment")
    }

    /// The nxdog69 builder's sequences: Computer Use on, then Reload
    /// Configuration; and off (the helper stops), then Reload Configuration.
    /// Each config load runs `ghostty_config_finalize`, which reads the
    /// `environ` slice libghostty kept from `ghostty_init`.
    @Test func turningComputerUseOnThenReloadingTheGhosttyConfigKeepsTheEnvironment() async {
        _ = GhosttyRuntime.shared
        let launcher = ComputerUseHelperDaemonTests.FakeLauncher()
        let (daemon, socket) = Self.daemon(launcher)
        defer { try? FileManager.default.removeItem(atPath: ((socket as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent) }
        let before = EnvironSnapshot.take()
        await daemon.apply(enabled: true)
        #expect(launcher.launches.count == 1)
        GhosttyRuntime.shared.reloadConfig()
        #expect(EnvironSnapshot.take() == before)
        daemon.applicationWillTerminate()
    }

    @Test func turningComputerUseOffThenReloadingTheGhosttyConfigKeepsTheEnvironment() async {
        _ = GhosttyRuntime.shared
        let launcher = ComputerUseHelperDaemonTests.FakeLauncher()
        let (daemon, socket) = Self.daemon(launcher)
        defer { try? FileManager.default.removeItem(atPath: ((socket as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent) }
        await daemon.apply(enabled: true)
        let before = EnvironSnapshot.take()
        await daemon.apply(enabled: false)
        #expect(launcher.terminated == [4242])
        GhosttyRuntime.shared.reloadConfig()
        #expect(EnvironSnapshot.take() == before)
    }
}
