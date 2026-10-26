import AppKit
import CmuxNextActions
import CmuxNextCompat
@testable import CmuxNextPalette
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// Each palette open is one `stall.palette_open` thread slice (p09-observability task 036): its begin and its end
/// are written in the open's own call while the stall category records, a page switch of the open palette is an
/// open too, and nothing is written while the category is off.
@MainActor @Suite(.paletteRanker, .serialized)
struct PaletteOpenSignpostTests {
    /// The `stall.palette_open` records of a test runtime.
    private final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var phases: [TraceRuntime.Phase] {
            state.withLock { $0 }.filter { $0.name == SignpostName.stallPaletteOpen.rawValue }.map(\.phase)
        }

        func signposter(recording: Bool) -> Signposter {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(recording ? 1 << UInt64(SignpostCategory.stall.traceBit) : 0)
            return Signposter(category: .stall, trace: runtime)
        }
    }

    private static func palette() -> PaletteController {
        _ = NSApplication.shared
        return PaletteController(registry: .standard(), frecencyPersistence: nil)
    }

    @Test func eachOpenIsOneSliceThatEndsInItsCall() {
        let log = RecordLog()
        let palette = Self.palette()
        defer { palette.hide() }
        palette.stallSignposter = log.signposter(recording: true)
        palette.show(.commands)
        #expect(log.phases == [.begin, .end])
        // Open already: switching its page in place is an open of its own.
        palette.show(.workspaces)
        #expect(log.phases == [.begin, .end, .begin, .end])
        palette.hide()
        palette.show(page: palette.commandsPage())
        #expect(log.phases == [.begin, .end, .begin, .end, .begin, .end])
    }

    @Test func nothingWhileTheStallCategoryIsOff() {
        let log = RecordLog()
        let palette = Self.palette()
        defer { palette.hide() }
        palette.stallSignposter = log.signposter(recording: false)
        palette.show(.commands)
        #expect(log.phases.isEmpty)
    }
}
