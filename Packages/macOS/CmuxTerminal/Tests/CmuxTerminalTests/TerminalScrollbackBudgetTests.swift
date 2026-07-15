import GhosttyKit
import GhosttyRuntimeTestStubs
import Testing

@testable import CmuxTerminal

@Suite("Terminal scrollback budget")
struct TerminalScrollbackBudgetTests {
    @Test func defaultBudgetCapsSixtyFourSurfacesAtFiveHundredTwelveMiB() {
        let budget = TerminalScrollbackBudget.cmuxDefault

        #expect(budget.maxBytesPerSurface == 8 * 1_048_576)
        #expect(budget.configuredCapBytes(surfaceCount: 64) == 512 * 1_048_576)
        #expect(budget.configuredCapBytes(surfaceCount: 128) == 1_024 * 1_048_576)
    }

    @Test func configuredCapScalesLinearlyBeyondSupportedSurfaceCount() {
        let budget = TerminalScrollbackBudget(
            targetAggregateScrollbackBytesAtSupportedScale: 100,
            supportedSurfaceCount: 4
        )

        #expect(budget.maxBytesPerSurface == 25)
        #expect(budget.configuredCapBytes(surfaceCount: 0) == 0)
        #expect(budget.configuredCapBytes(surfaceCount: 6) == 150)
    }

    @Test func runtimeConstructorPassesCapWithoutGrowingPublicConfig() throws {
        #expect(MemoryLayout<ghostty_surface_config_s>.size == 120)
        cmux_test_ghostty_runtime_stubs_reset()

        let configStorage = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<ghostty_surface_config_s>.size,
            alignment: MemoryLayout<ghostty_surface_config_s>.alignment
        )
        defer { configStorage.deallocate() }
        configStorage.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: MemoryLayout<ghostty_surface_config_s>.size
        )
        let config = configStorage.assumingMemoryBound(to: ghostty_surface_config_s.self)
        let app = try #require(ghostty_app_t(bitPattern: 0x1))

        _ = GhosttyRuntimeCInterop.createSurface(
            app: app,
            config: UnsafePointer(config),
            scrollbackLimitBytes: TerminalScrollbackBudget.cmuxDefault.maxBytesPerSurface
        )

        #expect(
            cmux_test_ghostty_surface_last_scrollback_limit_bytes()
                == UInt(TerminalScrollbackBudget.cmuxDefault.maxBytesPerSurface)
        )
    }
}
