import Foundation
import OSLog

struct TerminalInputDebugLog {
    private let isEnabled: Bool
    private let logger: Logger

    init(
        isEnabled: Bool = ProcessInfo.processInfo.environment["CMUX_INPUT_DEBUG"] == "1",
        logger: Logger = Logger(subsystem: "ai.manaflow.cmux.ios", category: "ghostty.input")
    ) {
        self.isEnabled = isEnabled
        self.logger = logger
    }

    func log(_ message: @autoclosure @escaping () -> String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        #endif
        guard isEnabled else { return }
        logger.debug("input: \(message(), privacy: .private)")
    }

    func textSummary(_ text: String) -> String {
        let summary = String(reflecting: text)
        guard summary.count > 96 else { return summary }
        return "\(summary.prefix(96))..."
    }

    func dataSummary(_ data: Data) -> String {
        let prefix = data.prefix(32)
        let prefixData = Data(prefix)
        let hex = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
        let utf8 = String(data: prefixData, encoding: .utf8) ?? "<non-utf8>"
        let suffix = data.count > prefix.count ? " ..." : ""
        return "len=\(data.count) hex=\(hex)\(suffix) utf8=\(textSummary(utf8))"
    }
}
