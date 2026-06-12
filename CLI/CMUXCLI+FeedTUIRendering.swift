import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Feed TUI rendering and input
extension CMUXCLI {
    func writeFeedTUIReadyMarker(stage: String) {
        guard let path = ProcessInfo.processInfo.environment["CMUX_FEED_TUI_READY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return
        }
        let url = URL(fileURLWithPath: path, isDirectory: false)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = """
        {"stage":"\(stage)","pid":"\(getpid())","time":"\(Date().timeIntervalSince1970)"}
        """
        try? payload.write(to: url, atomically: true, encoding: .utf8)
    }

    func feedTUIItems(client: SocketClient) throws -> [FeedTUIItem] {
        let payload = try client.sendV2(method: "feed.list", params: ["pending_only": true])
        let rawItems = payload["items"] as? [[String: Any]] ?? []
        return rawItems.compactMap(FeedTUIItem.parse)
            .filter(\.canResolve)
            .sorted { lhs, rhs in
                switch (lhs.createdAt, rhs.createdAt) {
                case (.some(let lhsDate), .some(let rhsDate)) where lhsDate != rhsDate:
                    return lhsDate > rhsDate
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    return lhs.id > rhs.id
                }
            }
    }

    func feedTUIItem(in items: [FeedTUIItem], at index: Int) -> FeedTUIItem? {
        guard index >= 0, index < items.count else { return nil }
        return items[index]
    }

    private func feedTUIOption(in options: [FeedTUIOption], at index: Int) -> FeedTUIOption? {
        guard index >= 0, index < options.count else { return nil }
        return options[index]
    }

    private struct FeedTUILayout {
        let width: Int
        let rows: Int

        let headerRows = 3
        let footerRows = 2
        let cardRows = 5

        var visibleItemCount: Int {
            max((rows - headerRows - footerRows) / cardRows, 1)
        }
    }

    func adjustedFeedTUIScrollOffset(
        itemCount: Int,
        selectedIndex: Int,
        scrollOffset: Int
    ) -> Int {
        guard itemCount > 0 else { return 0 }
        let size = currentCLITerminalSize()
        let layout = FeedTUILayout(width: max(size.cols, 1), rows: max(size.rows, 1))
        let visibleCount = layout.visibleItemCount
        let maxOffset = max(itemCount - visibleCount, 0)
        if selectedIndex < scrollOffset {
            return max(selectedIndex, 0)
        }
        if selectedIndex >= scrollOffset + visibleCount {
            return min(selectedIndex - visibleCount + 1, maxOffset)
        }
        return min(max(scrollOffset, 0), maxOffset)
    }

    func renderFeedTUI(
        items: [FeedTUIItem],
        selectedIndex: Int,
        scrollOffset: Int,
        statusLine: String
    ) {
        let size = currentCLITerminalSize()
        let layout = FeedTUILayout(width: max(size.cols, 1), rows: max(size.rows, 1))
        let width = layout.width
        let pendingCount = items.filter(\.isPending).count
        let visibleStart = items.isEmpty ? 0 : min(scrollOffset + 1, items.count)
        let visibleEnd = min(scrollOffset + layout.visibleItemCount, items.count)

        print("\u{001B}[2J\u{001B}[H", terminator: "")
        print(feedTUILine(
            "cmux Dock Feed  latest first  \(pendingCount) pending  \(items.count) total  \(visibleStart)-\(visibleEnd)",
            width: width
        ))
        print(feedTUILine(
            "j/k arrows move  enter default  d deny  f replan  r refresh  q quit",
            width: width
        ))
        print(feedTUISeparator(width: width))

        if items.isEmpty {
            print(feedTUILine("No feed items yet.", width: width))
        } else {
            for visibleIndex in 0..<layout.visibleItemCount {
                let itemIndex = scrollOffset + visibleIndex
                guard itemIndex < items.count else {
                    for _ in 0..<layout.cardRows {
                        print(feedTUILine("", width: width))
                    }
                    continue
                }
                let item = items[itemIndex]
                let selected = itemIndex == selectedIndex
                renderFeedTUICard(item, selected: selected, width: width)
            }
        }

        let footerTop = max(layout.rows - 1, 1)
        print("\u{001B}[\(footerTop);1H", terminator: "")
        print(feedTUISeparator(width: width), terminator: "")
        print("\u{001B}[\(layout.rows);1H", terminator: "")
        let footer = statusLine.isEmpty ? selectedHelp(feedTUIItem(in: items, at: selectedIndex)) : statusLine
        print(feedTUILine(footer, width: width), terminator: "")
        fflush(stdout)
    }

    private func renderFeedTUICard(_ item: FeedTUIItem, selected: Bool, width: Int) {
        let status = item.isPending ? "[PENDING]" : "[\(item.status.uppercased())]"
        let time = relativeFeedTUITime(since: item.createdAt)
        let kind = feedTUIKindLabel(item.kind)
        let source = sanitizedTerminalText(item.source)
        let marker = selected ? ">" : " "
        let metaSuffix = time.isEmpty ? kind : "\(kind)  \(time)"
        let detailLines = wrappedTerminalLines(item.detail, width: max(width - 4, 1), maxLines: 2)
        let firstDetailLine = detailLines.indices.contains(0) ? detailLines[0] : ""
        let secondDetailLine = detailLines.indices.contains(1) ? detailLines[1] : ""

        print(feedTUILine("\(marker) \(status) @\(source)  \(metaSuffix)", width: width, highlighted: selected))
        print(feedTUILine("  \(item.title)", width: width, highlighted: selected))
        print(feedTUILine("  \(firstDetailLine)", width: width, highlighted: selected))
        print(feedTUILine("  \(secondDetailLine)", width: width, highlighted: selected))
        print(feedTUISeparator(width: width))
    }

    private func feedTUIKindLabel(_ kind: String) -> String {
        switch kind {
        case "permissionRequest":
            return "permission"
        case "exitPlan":
            return "plan"
        case "question":
            return "question"
        default:
            return kind
        }
    }

    private func relativeFeedTUITime(since date: Date?) -> String {
        guard let date else { return "" }
        let seconds = max(Int(Date().timeIntervalSince(date)), 0)
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h"
        }
        return "\(hours / 24)d"
    }

    private func selectedHelp(_ item: FeedTUIItem?) -> String {
        guard let item else { return "No selection" }
        guard item.canResolve else { return "Resolved or informational item" }
        switch item.kind {
        case "permissionRequest":
            let supportsOnce = feedTUISourceSupportsOncePermissionMode(
                item.source,
                toolInputJSON: item.toolInputCapabilitiesJSON
            )
            let supportsAlways = feedTUISourceSupportsAlwaysPermissionMode(
                item.source,
                toolInputJSON: item.toolInputCapabilitiesJSON
            )
            let supportsAll = feedTUISourceSupportsAllPermissionMode(
                item.source,
                toolInputJSON: item.toolInputCapabilitiesJSON
            )
            var actions: [String] = []
            if supportsOnce { actions.append("Enter/o once") }
            if supportsAlways { actions.append("a always") }
            if supportsAll { actions.append("l all tools") }
            if feedTUISourceSupportsBypassPermissions(item.source) { actions.append("b bypass") }
            actions.append("d deny")
            return "Permission: \(actions.joined(separator: ", "))"
        case "exitPlan":
            if !feedTUISourceSupportsBypassPermissions(item.source) {
                return "Plan: Enter default, a auto, m manual, u ultraplan, f replan, d deny"
            }
            return "Plan: Enter default, a auto, m manual, u ultraplan, b bypass, f replan, d deny"
        case "question":
            let questionCount = max(item.questions.count, 1)
            let firstQuestion = item.questions.first
            let optionText = (firstQuestion?.options ?? item.questionOptions).enumerated().map { index, option in
                "\(index + 1)=\(option.label)"
            }.joined(separator: "  ")
            if questionCount > 1 {
                return "Question: Enter sends defaults for \(questionCount) prompts"
            }
            if optionText.isEmpty {
                return "Question: Enter sends an empty answer"
            }
            let suffix = (firstQuestion?.multiSelect ?? item.questionMultiSelect) ? "  Enter sends selected options" : ""
            return "Question: \(optionText)\(suffix)"
        default:
            return ""
        }
    }

    private func feedTUISourceSupportsOncePermissionMode(_ source: String, toolInputJSON: String?) -> Bool {
        CMUXCLI.feedSourceSupportsOncePermissionMode(source, toolInputJSON: toolInputJSON)
    }

    private func feedTUISourceSupportsAlwaysPermissionMode(_ source: String, toolInputJSON: String?) -> Bool {
        CMUXCLI.feedSourceSupportsAlwaysPermissionMode(source, toolInputJSON: toolInputJSON)
    }

    private func feedTUISourceSupportsAllPermissionMode(_ source: String, toolInputJSON: String?) -> Bool {
        CMUXCLI.feedSourceSupportsAllPermissionMode(source, toolInputJSON: toolInputJSON)
    }

    private func feedTUISourceSupportsBypassPermissions(_ source: String) -> Bool {
        CMUXCLI.feedSourceSupportsBypassPermissions(source)
    }

    static func feedSourceSupportsOncePermissionMode(_ source: String, toolInputJSON: String?) -> Bool {
        CodexTeamsApprovalBridge.feedSourceSupportsOncePermissionMode(source, toolInputJSON: toolInputJSON)
    }

    static func feedSourceSupportsAlwaysPermissionMode(_ source: String, toolInputJSON: String?) -> Bool {
        CodexTeamsApprovalBridge.feedSourceSupportsAlwaysPermissionMode(source, toolInputJSON: toolInputJSON)
    }

    static func feedSourceSupportsAllPermissionMode(_ source: String, toolInputJSON: String?) -> Bool {
        CodexTeamsApprovalBridge.feedSourceSupportsAllPermissionMode(source, toolInputJSON: toolInputJSON)
    }

    static func feedSourceSupportsBypassPermissions(_ source: String) -> Bool {
        CodexTeamsApprovalBridge.feedSourceSupportsBypassPermissions(source)
    }

    func resolveFeedTUIItem(
        _ item: FeedTUIItem,
        key: FeedTUIKey,
        client: SocketClient,
        rawMode: inout TerminalRawMode?,
        selectedQuestionOptions: inout [String: Set<String>]
    ) throws -> String {
        guard item.canResolve, let requestId = item.requestId else {
            return "No pending action for selected item"
        }

        switch item.kind {
        case "permissionRequest":
            let mode: String
            switch key {
            case .enter where feedTUISourceSupportsOncePermissionMode(
                item.source,
                toolInputJSON: item.toolInputCapabilitiesJSON
            ),
            .once where feedTUISourceSupportsOncePermissionMode(
                item.source,
                toolInputJSON: item.toolInputCapabilitiesJSON
            ):
                mode = "once"
            case .always where feedTUISourceSupportsAlwaysPermissionMode(
                item.source,
                toolInputJSON: item.toolInputCapabilitiesJSON
            ):
                mode = "always"
            case .all where feedTUISourceSupportsAllPermissionMode(
                item.source,
                toolInputJSON: item.toolInputCapabilitiesJSON
            ):
                mode = "all"
            case .bypass where feedTUISourceSupportsBypassPermissions(item.source):
                mode = "bypass"
            case .deny:
                mode = "deny"
            default:
                return "Key is not available for permission requests"
            }
            _ = try client.sendV2(
                method: "feed.permission.reply",
                params: ["request_id": requestId, "mode": mode]
            )
            return "Permission \(mode) sent"
        case "exitPlan":
            if key == .feedback {
                let feedback = readFeedTUIFeedbackPrompt(rawMode: &rawMode)
                guard !feedback.isEmpty else { return "Replan cancelled" }
                _ = try client.sendV2(
                    method: "feed.exit_plan.reply",
                    params: ["request_id": requestId, "mode": "deny", "feedback": feedback]
                )
                return "Replan feedback sent"
            }

            let mode: String
            switch key {
            case .enter:
                mode = item.defaultMode ?? "manual"
            case .autoAccept, .always:
                mode = "autoAccept"
            case .manual:
                mode = "manual"
            case .ultraplan:
                mode = "ultraplan"
            case .bypass where feedTUISourceSupportsBypassPermissions(item.source):
                mode = "bypassPermissions"
            case .deny:
                mode = "deny"
            default:
                return "Key is not available for plans"
            }
            _ = try client.sendV2(
                method: "feed.exit_plan.reply",
                params: ["request_id": requestId, "mode": mode]
            )
            return "Plan \(mode) sent"
        case "question":
            let primaryQuestion = item.questions.first
            let primaryOptions = primaryQuestion?.options ?? item.questionOptions
            let primaryMultiSelect = primaryQuestion?.multiSelect ?? item.questionMultiSelect
            if primaryOptions.isEmpty {
                guard key == .enter else {
                    return "Question has no selectable options"
                }
                _ = try client.sendV2(
                    method: "feed.question.reply",
                    params: ["request_id": requestId, "selections": [] as [String]]
                )
                return "Question answer sent"
            }

            if item.questions.count > 1, key == .enter {
                let selections = item.questions.map { question in
                    question.options.first?.label ?? ""
                }
                _ = try client.sendV2(
                    method: "feed.question.reply",
                    params: ["request_id": requestId, "selections": selections]
                )
                return "Question answer sent"
            }

            if primaryMultiSelect {
                switch key {
                case .number(let index):
                    guard let option = feedTUIOption(in: primaryOptions, at: index - 1) else {
                        return "No option \(index)"
                    }
                    var selections = selectedQuestionOptions[requestId] ?? Set<String>()
                    if selections.contains(option.id) {
                        selections.remove(option.id)
                        selectedQuestionOptions[requestId] = selections
                        return "Unselected: \(option.label)"
                    }
                    selections.insert(option.id)
                    selectedQuestionOptions[requestId] = selections
                    return "Selected: \(option.label)"
                case .enter:
                    let selected = selectedQuestionOptions[requestId] ?? Set<String>()
                    let selections = primaryOptions
                        .filter { selected.contains($0.id) }
                        .map(\.label)
                    _ = try client.sendV2(
                        method: "feed.question.reply",
                        params: ["request_id": requestId, "selections": selections]
                    )
                    selectedQuestionOptions.removeValue(forKey: requestId)
                    return selections.isEmpty ? "Question answer sent with no selections" : "Question answer sent"
                default:
                    return "Key is not available for questions"
                }
            }

            let option: FeedTUIOption?
            switch key {
            case .number(let index):
                option = feedTUIOption(in: primaryOptions, at: index - 1)
            case .enter:
                option = primaryOptions.first
            default:
                return "Key is not available for questions"
            }
            guard let option else {
                return "No question option available"
            }
            _ = try client.sendV2(
                method: "feed.question.reply",
                params: ["request_id": requestId, "selections": [option.label]]
            )
            return "Question answer sent: \(option.label)"
        default:
            return "Unsupported feed item"
        }
    }

    private func readFeedTUIFeedbackPrompt(rawMode: inout TerminalRawMode?) -> String {
        rawMode?.restore()
        print("\u{001B}[2J\u{001B}[H", terminator: "")
        print("Tell the agent what to change, then press Return.")
        print("> ", terminator: "")
        fflush(stdout)
        let value = readLine() ?? ""
        guard let restoredRawMode = TerminalRawMode() else {
            return ""
        }
        rawMode = restoredRawMode
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func readFeedTUIKey(timeoutMilliseconds: Int32? = nil) -> FeedTUIKey {
        if let timeoutMilliseconds {
            while true {
                var descriptor = pollfd(
                    fd: STDIN_FILENO,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
                let ready = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return .ignored
                }
                if ready == 0 {
                    return .tick
                }
                if descriptor.revents & Int16(POLLHUP) != 0 {
                    return .quit
                }
                if descriptor.revents & Int16(POLLIN) == 0 {
                    return .ignored
                }
                break
            }
        }

        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                return .ignored
            }
            if count == 0 { return .quit }
            break
        }

        switch byte {
        case 3:
            return .quit
        case 10, 13:
            return .enter
        case 27:
            guard let first = readFeedTUIByteIfReady(timeoutMilliseconds: 25),
                  let second = readFeedTUIByteIfReady(timeoutMilliseconds: 25),
                  first == 91 else {
                return .ignored
            }
            switch second {
            case 65: return .up
            case 66: return .down
            default: return .ignored
            }
        case 106, 74:
            return .down
        case 107, 75:
            return .up
        case 113, 81:
            return .quit
        case 114, 82:
            return .refresh
        case 100, 68:
            return .deny
        case 102, 70:
            return .feedback
        case 111, 79:
            return .once
        case 97, 65:
            return .always
        case 108, 76:
            return .all
        case 98, 66:
            return .bypass
        case 109, 77:
            return .manual
        case 117, 85:
            return .ultraplan
        case 49...57:
            return .number(Int(byte - 48))
        case 48:
            return .number(10)
        default:
            return .ignored
        }
    }

    private func readFeedTUIByteIfReady(timeoutMilliseconds: Int32) -> UInt8? {
        while true {
            var descriptor = pollfd(
                fd: STDIN_FILENO,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let ready = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard ready > 0, descriptor.revents & Int16(POLLIN) != 0 else {
                return nil
            }
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            return count == 1 ? byte : nil
        }
    }

    func currentCLITerminalSize() -> (cols: Int, rows: Int) {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0,
           size.ws_col > 0,
           size.ws_row > 0 {
            return (Int(size.ws_col), Int(size.ws_row))
        }
        return (80, 24)
    }

    private func feedTUISeparator(width: Int) -> String {
        String(repeating: "-", count: max(width, 0))
    }

    private func feedTUILine(
        _ value: String,
        width: Int,
        highlighted: Bool = false
    ) -> String {
        let line = paddedTerminalLine(truncateForTerminal(value, width: width), width: width)
        guard highlighted else { return line }
        return "\u{001B}[7m\(line)\u{001B}[0m"
    }

    private func paddedTerminalLine(_ value: String, width: Int) -> String {
        guard width > 0 else { return "" }
        if value.count >= width {
            return value
        }
        return value + String(repeating: " ", count: width - value.count)
    }

    private func wrappedTerminalLines(_ value: String, width: Int, maxLines: Int) -> [String] {
        guard maxLines > 0 else { return [] }
        guard width > 0 else { return Array(repeating: "", count: maxLines) }

        var remainder = sanitizedTerminalText(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []

        while lines.count < maxLines, !remainder.isEmpty {
            if remainder.count <= width {
                lines.append(remainder)
                remainder = ""
                break
            }

            let limitIndex = remainder.index(remainder.startIndex, offsetBy: width)
            let candidate = remainder[..<limitIndex]
            if let splitIndex = candidate.lastIndex(of: " ") {
                let line = String(remainder[..<splitIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(line.isEmpty ? String(candidate) : line)
                remainder = String(remainder[splitIndex...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                lines.append(String(candidate))
                remainder = String(remainder[limitIndex...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if !remainder.isEmpty, !lines.isEmpty {
            lines[lines.count - 1] = truncateForTerminal("\(lines[lines.count - 1]) ...", width: width)
        }

        while lines.count < maxLines {
            lines.append("")
        }
        return lines
    }

    private func sanitizedTerminalText(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                output.append(" ")
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
            .replacingOccurrences(of: "\u{001B}", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private func truncateForTerminal(_ value: String, width: Int) -> String {
        guard width > 0 else { return "" }
        let sanitized = sanitizedTerminalText(value)
        if sanitized.count <= width { return sanitized }
        let suffix = "..."
        guard width > suffix.count else {
            let end = sanitized.index(sanitized.startIndex, offsetBy: width)
            return String(sanitized[..<end])
        }
        let end = sanitized.index(sanitized.startIndex, offsetBy: width - suffix.count)
        return String(sanitized[..<end]) + suffix
    }

    func runFeedClear() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("workstream.jsonl", isDirectory: false)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            print("No Feed history to clear (\(path.path) does not exist).")
            return
        }
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        if !skipConfirm {
            print("This will permanently delete \(path.path). Proceed? [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print("Aborted.")
                return
            }
        }
        try fm.removeItem(at: path)
        print("Cleared \(path.path)")
    }

    // MARK: - OpenCode plugin install

}
