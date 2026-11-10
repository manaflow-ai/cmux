public import Foundation

public nonisolated enum AgentPaneIMessageAction: String, Equatable, Sendable, CaseIterable {
    case status, connect, disconnect, threads, automation
    case fullDiskAccess = "full_disk_access"
    case skipAutomation = "skip_automation"

    public var isPassive: Bool { self == .status || self == .threads }
}

public extension AgentPaneView {
    /// Permission changes invalidate the local connector, without broadcasting any chat data.
    func iMessageChanged() {
        deliver([AgentPageEvent(kind: "imessage.changed", value: .null)],
                scripts: ["window.dispatchEvent(new Event('cmux-imessage-changed'));"])
    }
}
