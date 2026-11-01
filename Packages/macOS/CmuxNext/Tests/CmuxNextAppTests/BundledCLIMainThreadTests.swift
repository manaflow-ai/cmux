@testable import CmuxNextApp
@testable import CmuxNextCompat
import Foundation
import Testing

/// The bundled `cmux` that TopPages (Automations), PageFactory (agent integrations), ChiefMoveHandlers and the
/// server source ask for: they ask on the main thread, at registration or in a menu's availability check, so
/// asking makes no file system call there. Whether the binary is there is answered off the main thread.
@Suite
struct BundledCLIMainThreadTests {
    #if DEBUG
    @MainActor @Test func askingForTheBundledCLIOnTheMainThreadTouchesNoFile() async {
        let table = BlockingViolationTable(mode: .record)
        BlockingViolationTable.$scoped.withValue(table) {
            _ = LocalServerSource.bundledCLI()
        }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }
    #endif
}
