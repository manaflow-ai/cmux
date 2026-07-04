@testable import CmuxUpdater

struct NullUpdateLog: UpdateLogging {
    func append(_ message: String) {}
    func logPath() -> String { "/tmp/cmux-update-test.log" }
}
